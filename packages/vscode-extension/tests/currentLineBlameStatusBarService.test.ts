import { afterEach, describe, expect, it, vi } from "vitest";
import { CurrentLineBlameStatusBarService } from "../src/lens/currentLineBlameStatusBarService";
import type { HistoryBlame, HistoryBlameClient, HistoryBlameRequest } from "../src/history/historyBlameRpcClient";
import type { LensSettings } from "../src/lens/lensSettings";
import type { RepositorySession, RepositorySessionService } from "../src/repository/repositorySessionService";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type {
  ScmProjectedResource,
  ScmProjectedResourceLookup,
  ScmRepositoryProjection,
} from "../src/scm/sourceControlResourceStore";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";

describe("CurrentLineBlameStatusBarService", () => {
  afterEach(() => {
    pendingTimers.length = 0;
  });

  it("shows a localized single-line blame status for a projected text-stable SVN file", async () => {
    const statusItem = fakeStatusItem();
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 2 }));
    const service = currentLineBlameService({
      api: fakeApi({
        activeEditor: textEditor("C:\\workspace\\SRC\\MAIN.C", 1),
        statusItem,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(historyClient.getBlame).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      pegRevision: "base",
      startRevision: "r0",
      endRevision: "base",
      lineStart: 2,
      lineLimit: 1,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
    });
    expect(statusItem.text).toBe("$(history) l10n:SVN r4 alice");
    expect(statusItem.tooltip).toBe("l10n:SVN blame for src/main.c:2");
    expect(statusItem.command).toEqual({
      command: "subversionr.showBlame",
      title: "l10n:Blame",
      arguments: [
        {
          contextValue: "subversionr.changedFile",
          subversionrResourceKind: "file",
          subversionrProjectionGeneration: 11,
          resourceUri: { scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" },
        },
      ],
    });
    expect(statusItem.show).toHaveBeenCalled();
    expect(statusItem.hide).not.toHaveBeenCalled();
  });

  it("shows current-line blame for a projected text-stable SVN file inside a changelist", async () => {
    const statusItem = fakeStatusItem();
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 3, path: "src/review.c" }));
    const service = currentLineBlameService({
      api: fakeApi({
        activeEditor: textEditor("C:\\workspace\\src\\review.c", 2),
        statusItem,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource(
                {
                  path: "src/review.c",
                  changelist: "review",
                  localStatus: "modified",
                  textStatus: "normal",
                  propertyStatus: "modified",
                },
                {
                  groupId: "changelist:review",
                  contextValue: "subversionr.changedFile",
                },
              ),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(historyClient.getBlame).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/review.c",
      pegRevision: "base",
      startRevision: "r0",
      endRevision: "base",
      lineStart: 3,
      lineLimit: 1,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
    });
    expect(statusItem.text).toBe("$(history) l10n:SVN r4 alice");
    expect(statusItem.command).toEqual({
      command: "subversionr.showBlame",
      title: "l10n:Blame",
      arguments: [
        {
          contextValue: "subversionr.changedFile",
          subversionrResourceKind: "file",
          subversionrProjectionGeneration: 11,
          resourceUri: { scheme: "file", fsPath: "C:\\workspace\\src\\review.c" },
        },
      ],
    });
    expect(statusItem.show).toHaveBeenCalled();
    expect(statusItem.hide).not.toHaveBeenCalled();
  });

  it("includes merged revisions in current-line blame status requests when history settings enable them", async () => {
    const statusItem = fakeStatusItem();
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 2 }));
    const service = currentLineBlameService({
      includeMergedRevisions: () => true,
      api: fakeApi({
        activeEditor: textEditor("C:\\workspace\\src\\main.c", 1),
        statusItem,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(historyClient.getBlame).toHaveBeenCalledWith(
      expect.objectContaining({
        includeMergedRevisions: true,
      }),
    );
    expect(statusItem.text).toBe("$(history) l10n:SVN r4 alice");
  });

  it("does not request blame in untrusted workspaces", async () => {
    const statusItem = fakeStatusItem();
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 2 }));
    const service = currentLineBlameService({
      workspaceTrusted: false,
      api: fakeApi({
        activeEditor: textEditor("C:\\workspace\\src\\main.c", 1),
        statusItem,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(statusItem.hide).toHaveBeenCalled();
    expect(statusItem.show).not.toHaveBeenCalled();
  });

  it.each([
    ["modified", "modified"],
    ["obstructed", "obstructed"],
    ["incomplete", "incomplete"],
  ])("does not request blame for %s resources until working-copy line mapping exists", async (_label, textStatus) => {
    const statusItem = fakeStatusItem();
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 2 }));
    const service = currentLineBlameService({
      api: fakeApi({
        activeEditor: textEditor("C:\\workspace\\src\\main.c", 1),
        statusItem,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                textStatus,
              }),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(statusItem.hide).toHaveBeenCalled();
  });

  it.each([
    ["added", "added"],
    ["replaced", "replaced"],
    ["obstructed", "obstructed"],
    ["incomplete", "incomplete"],
  ])("does not request blame for %s node states with normal text status", async (_label, nodeStatus) => {
    const statusItem = fakeStatusItem();
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 2 }));
    const service = currentLineBlameService({
      api: fakeApi({
        activeEditor: textEditor("C:\\workspace\\src\\main.c", 1),
        statusItem,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: nodeStatus,
                nodeStatus,
                textStatus: "normal",
              }),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(statusItem.hide).toHaveBeenCalled();
  });

  it.each(["added", "replaced", "obstructed", "incomplete", "conflicted"])(
    "does not request blame for %s local states with normal node and text status",
    async (localStatus) => {
      const statusItem = fakeStatusItem();
      const historyClient = fakeHistoryClient(blameResponse({ lineStart: 2 }));
      const service = currentLineBlameService({
        api: fakeApi({
          activeEditor: textEditor("C:\\workspace\\src\\main.c", 1),
          statusItem,
        }),
        historyClient,
        projections: new Map([
          [
            "repo-uuid:C:/workspace",
            scmProjection({
              resources: [
                scmProjectedResource({
                  localStatus,
                  nodeStatus: "normal",
                  textStatus: "normal",
                }),
              ],
            }),
          ],
        ]),
      });

      await service.refresh();

      expect(historyClient.getBlame).not.toHaveBeenCalled();
      expect(statusItem.hide).toHaveBeenCalled();
    },
  );

  it("hides without projection lookup when current-line blame is disabled or the editor is outside open repositories", async () => {
    const getProjectedResource = vi.fn<SourceControlProjectionService["getProjectedResource"]>();
    const statusItem = fakeStatusItem();
    const service = currentLineBlameService({
      settings: lensSettings({ currentLine: false }),
      api: fakeApi({
        activeEditor: textEditor("D:\\outside\\src\\main.c", 0),
        statusItem,
      }),
      sourceControlProjection: { getProjectedResource },
    });

    await service.refresh();

    expect(getProjectedResource).not.toHaveBeenCalled();
    expect(statusItem.hide).toHaveBeenCalled();
  });

  it("does not request blame for dirty editors until working-copy line mapping exists", async () => {
    const statusItem = fakeStatusItem();
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 2 }));
    const service = currentLineBlameService({
      api: fakeApi({
        activeEditor: textEditor("C:\\workspace\\src\\main.c", 1, { isDirty: true }),
        statusItem,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(statusItem.hide).toHaveBeenCalled();
  });

  it("hides previously shown blame immediately when the active editor becomes dirty", async () => {
    const statusItem = fakeStatusItem();
    const editor = textEditor("C:\\workspace\\src\\main.c", 1);
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 2 }));
    const service = currentLineBlameService({
      api: fakeApi({
        activeEditor: () => editor,
        statusItem,
        deferTimers: true,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    const cleanRefresh = service.refresh();
    await runPendingTimer();
    await cleanRefresh;
    expect(statusItem.text).toBe("$(history) l10n:SVN r4 alice");

    editor.document.isDirty = true;
    const dirtyRefresh = service.refresh();

    expect(statusItem.hide).toHaveBeenCalled();
    expect(statusItem.text).toBeUndefined();
    await dirtyRefresh;
    expect(historyClient.getBlame).toHaveBeenCalledTimes(1);
  });

  it("discards stale blame results when the active editor changes during an in-flight request", async () => {
    const firstBlame = deferred<HistoryBlame>();
    const historyClient = {
      getBlame: vi.fn(() => firstBlame.promise),
    };
    const statusItem = fakeStatusItem();
    const activeEditor = { current: textEditor("C:\\workspace\\src\\main.c", 1) };
    const service = currentLineBlameService({
      api: fakeApi({
        activeEditor: () => activeEditor.current,
        statusItem,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    const inFlight = service.refresh();
    activeEditor.current = textEditor("D:\\outside\\src\\main.c", 1);
    await service.refresh();
    firstBlame.resolve(blameResponse({ lineStart: 2 }));
    await inFlight;

    expect(statusItem.text).toBeUndefined();
    expect(statusItem.hide).toHaveBeenCalled();
    expect(statusItem.show).toHaveBeenCalledTimes(1);
  });

  it("hides the status item when foreground one-line blame fails", async () => {
    const statusItem = fakeStatusItem();
    const historyClient = {
      getBlame: vi.fn(async () => {
        throw new Error("backend unavailable");
      }),
    };
    const service = currentLineBlameService({
      api: fakeApi({
        activeEditor: textEditor("C:\\workspace\\src\\main.c", 1),
        statusItem,
      }),
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    await expect(service.refresh()).resolves.toBeUndefined();

    expect(statusItem.hide).toHaveBeenCalled();
    expect(statusItem.text).toBeUndefined();
  });

  it("hides and settles when projection lookup throws during refresh", async () => {
    const statusItem = fakeStatusItem();
    const service = currentLineBlameService({
      api: fakeApi({
        activeEditor: textEditor("C:\\workspace\\src\\main.c", 1),
        statusItem,
      }),
      sourceControlProjection: {
        getProjectedResource: () => {
          throw new Error("projection unavailable");
        },
      },
    });

    await expect(service.refresh()).resolves.toBeUndefined();

    expect(statusItem.hide).toHaveBeenCalled();
  });
});

function currentLineBlameService(options: {
  settings?: LensSettings;
  includeMergedRevisions?: () => boolean;
  historyClient?: HistoryBlameClient;
  sessions?: RepositorySession[];
  projections?: Map<string, ScmRepositoryProjection | undefined>;
  sourceControlProjection?: Pick<SourceControlProjectionService, "getProjectedResource">;
  api?: FakeApi;
  workspaceTrusted?: boolean;
} = {}): CurrentLineBlameStatusBarService {
  const projections = options.projections ?? new Map([["repo-uuid:C:/workspace", scmProjection()]]);
  return new CurrentLineBlameStatusBarService({
    settings: () => options.settings ?? lensSettings(),
    includeMergedRevisions: options.includeMergedRevisions ?? (() => false),
    historyClient: options.historyClient ?? fakeHistoryClient(blameResponse({ lineStart: 2 })),
    sessionService: fakeSessionService(options.sessions ?? [repositorySession()]),
    sourceControlProjection: options.sourceControlProjection ?? fakeSourceControlProjection(projections),
    workspaceTrusted: () => options.workspaceTrusted ?? true,
    api:
      options.api ??
      fakeApi({
        activeEditor: textEditor("C:\\workspace\\src\\main.c", 1),
        statusItem: fakeStatusItem(),
      }),
  });
}

function fakeApi(options: {
  activeEditor: CurrentLineBlameTextEditor | (() => CurrentLineBlameTextEditor | undefined) | undefined;
  statusItem: FakeStatusItem;
  deferTimers?: boolean;
}): FakeApi {
  let activeTextEditor: () => CurrentLineBlameTextEditor | undefined;
  if (typeof options.activeEditor === "function") {
    activeTextEditor = options.activeEditor;
  } else {
    const editor = options.activeEditor;
    activeTextEditor = vi.fn(() => editor);
  }
  return {
    activeTextEditor,
    createStatusBarItem: vi.fn(() => options.statusItem),
    localize: (message, ...args) =>
      `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
    setTimeout: (callback) => {
      if (options.deferTimers) {
        pendingTimers.push(callback);
        return pendingTimers.length;
      }
      callback();
      return 1;
    },
    clearTimeout: vi.fn(),
  };
}

async function runPendingTimer(): Promise<void> {
  const callback = pendingTimers.shift();
  if (!callback) {
    throw new Error("Expected a pending timer");
  }
  callback();
  await Promise.resolve();
}

function fakeStatusItem(): FakeStatusItem {
  return {
    show: vi.fn(),
    hide: vi.fn(function (this: FakeStatusItem) {
      this.text = undefined;
      this.tooltip = undefined;
      this.command = undefined;
    }),
    dispose: vi.fn(),
  };
}

function fakeHistoryClient(blame: HistoryBlame): HistoryBlameClient & {
  getBlame: ReturnType<typeof vi.fn<(request: HistoryBlameRequest) => Promise<HistoryBlame>>>;
} {
  return {
    getBlame: vi.fn(async () => blame),
  };
}

function fakeSessionService(sessions: RepositorySession[]): Pick<RepositorySessionService, "listOpenSessions"> {
  return {
    listOpenSessions: () => sessions,
  };
}

function fakeSourceControlProjection(
  projections: Map<string, ScmRepositoryProjection | undefined>,
): Pick<SourceControlProjectionService, "getProjectedResource"> {
  return {
    getProjectedResource: (repositoryId, path, pathCase) => {
      const projection = projections.get(repositoryId);
      if (!projection) {
        return undefined;
      }
      const resource = projection.groups
        .flatMap((group) => group.resources)
        .find((candidate) => comparisonKey(pathCase, candidate.path) === comparisonKey(pathCase, path));
      return resource ? lookup(projection, resource) : undefined;
    },
  };
}

function lookup(projection: ScmRepositoryProjection, resource: ScmProjectedResource): ScmProjectedResourceLookup {
  return {
    repositoryId: projection.repositoryId,
    epoch: projection.epoch,
    workingCopyRoot: projection.workingCopyRoot,
    generation: projection.generation,
    resource,
  };
}

function comparisonKey(pathCase: "case-sensitive" | "case-insensitive", path: string): string {
  return pathCase === "case-insensitive" ? path.toLocaleLowerCase("en-US") : path;
}

function repositorySession(
  overrides: Partial<{ repositoryId: string; workingCopyRoot: string }> = {},
): RepositorySession {
  const repositoryId = overrides.repositoryId ?? "repo-uuid:C:/workspace";
  const workingCopyRoot = overrides.workingCopyRoot ?? "C:\\workspace";
  return {
    repositoryId,
    epoch: 7,
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: "file:///C:/repo",
      workingCopyRoot,
      workspaceScopeRoot: workingCopyRoot,
      format: 31,
    },
    watchScope: {
      repositoryId,
      epoch: 7,
      workingCopyRoot,
      pathCase: "case-insensitive",
    },
  };
}

function scmProjection(options: {
  repositoryId?: string;
  workingCopyRoot?: string;
  resources?: ScmProjectedResource[];
} = {}): ScmRepositoryProjection {
  return {
    repositoryId: options.repositoryId ?? "repo-uuid:C:/workspace",
    epoch: 7,
    workingCopyRoot: options.workingCopyRoot ?? "C:/workspace",
    generation: 11,
    count: 1,
    freshness: {
      repositoryCompleteness: "complete",
      lastRefreshCompleteness: "complete",
      lastRefreshKind: "snapshot",
    },
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      { id: "changes", labelKey: "scm.group.changes", changelist: null, resources: options.resources ?? [scmProjectedResource()] },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function scmProjectedResource(
  overrides: Partial<StatusEntry> = {},
  projectionOverrides: Partial<Pick<ScmProjectedResource, "source" | "groupId" | "contextValue">> = {},
): ScmProjectedResource {
  const entry = statusEntry(overrides);
  return {
    key: `${projectionOverrides.source ?? "local"}:${entry.path}`,
    repositoryId: "repo-uuid:C:/workspace",
    path: entry.path,
    source: projectionOverrides.source ?? "local",
    groupId: projectionOverrides.groupId ?? "changes",
    contextValue: projectionOverrides.contextValue ?? "subversionr.changedFile",
    tooltipKey: "scm.resource.changed",
    entry,
  };
}

function statusEntry(overrides: Partial<StatusEntry> = {}): StatusEntry {
  return {
    path: overrides.path ?? "src/main.c",
    kind: overrides.kind ?? "file",
    nodeStatus: overrides.nodeStatus ?? "normal",
    textStatus: overrides.textStatus ?? "modified",
    propertyStatus: overrides.propertyStatus ?? "normal",
    localStatus: overrides.localStatus ?? "modified",
    remoteStatus: overrides.remoteStatus ?? "none",
    revision: overrides.revision ?? 3,
    changedRevision: overrides.changedRevision ?? 3,
    changedAuthor: overrides.changedAuthor ?? "alice",
    changedDate: overrides.changedDate ?? "2026-06-22T00:00:00Z",
    changelist: overrides.changelist ?? null,
    lock: overrides.lock ?? null,
    needsLock: overrides.needsLock ?? false,
    copy: overrides.copy ?? null,
    move: overrides.move ?? null,
    switched: overrides.switched ?? false,
    depth: overrides.depth ?? "infinity",
    conflict: overrides.conflict ?? null,
    external: overrides.external ?? false,
    generation: overrides.generation ?? 11,
  };
}

function lensSettings(overrides: Partial<LensSettings> = {}): LensSettings {
  return {
    enabled: true,
    fileHeader: true,
    currentLine: true,
    hover: true,
    symbols: false,
    maxFileLines: 20000,
    ...overrides,
  };
}

function textEditor(
  fsPath: string,
  activeLine: number,
  options: { lineCount?: number; scheme?: string; isDirty?: boolean } = {},
): CurrentLineBlameTextEditor {
  return {
    document: {
      uri: {
        scheme: options.scheme ?? "file",
        fsPath,
      },
      lineCount: options.lineCount ?? 20,
      isDirty: options.isDirty ?? false,
    },
    selection: {
      active: {
        line: activeLine,
      },
    },
  };
}

function blameResponse(options: { lineStart: number; path?: string }): HistoryBlame {
  return {
    repositoryId: "repo-uuid:C:/workspace",
    epoch: 7,
    path: options.path ?? "src/main.c",
    pegRevision: "base",
    startRevision: "r0" as HistoryBlame["startRevision"],
    endRevision: "base",
    resolvedStartRevision: 1,
    resolvedEndRevision: 4,
    lineStart: options.lineStart,
    lineLimit: 1,
    ignoreWhitespace: "none",
    ignoreEolStyle: false,
    ignoreMimeType: false,
    includeMergedRevisions: false,
    hasMore: false,
    lines: [
      {
        lineNumber: options.lineStart,
        revision: 4,
        author: "alice",
        date: "2026-06-22T00:00:00.000000Z",
        mergedRevision: null,
        mergedAuthor: null,
        mergedDate: null,
        mergedPath: null,
        lineBase64: "dGVzdA==",
        byteLength: 4,
        localChange: false,
      },
    ],
    source: "libsvn-blame",
  };
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
} {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((innerResolve) => {
    resolve = innerResolve;
  });
  return { promise, resolve };
}

interface CurrentLineBlameTextEditor {
  document: {
    uri: {
      scheme: string;
      fsPath: string;
    };
    lineCount: number;
    isDirty: boolean;
  };
  selection: {
    active: {
      line: number;
    };
  };
}

interface FakeStatusItem {
  text?: string;
  tooltip?: string;
  command?: unknown;
  show: ReturnType<typeof vi.fn<() => void>>;
  hide: ReturnType<typeof vi.fn<() => void>>;
  dispose: ReturnType<typeof vi.fn<() => void>>;
}

interface FakeApi {
  activeTextEditor(): CurrentLineBlameTextEditor | undefined;
  createStatusBarItem(): FakeStatusItem;
  localize(message: string, ...args: unknown[]): string;
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
}

const pendingTimers: Array<() => void> = [];

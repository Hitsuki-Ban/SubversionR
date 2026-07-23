import { Buffer } from "node:buffer";
import { describe, expect, it, vi } from "vitest";
import { CurrentLineBlameHoverProvider } from "../src/lens/currentLineBlameHoverProvider";
import type { HistoryBlame, HistoryBlameClient, HistoryBlameRequest } from "../src/history/historyBlameRpcClient";
import type { HistoryClient as HistoryLogClient, HistoryLog, HistoryLogRequest } from "../src/history/historyLogRpcClient";
import type { LensSettings } from "../src/lens/lensSettings";
import type { RepositorySession, RepositorySessionService } from "../src/repository/repositorySessionService";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type {
  ScmProjectedResource,
  ScmProjectedResourceLookup,
  ScmRepositoryProjection,
} from "../src/scm/sourceControlResourceStore";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";
import { anonymousSvnRemoteEnvelope } from "./remoteOperationEnvelopeFixture";

describe("CurrentLineBlameHoverProvider", () => {
  it("returns localized one-line SVN blame hover with the first log-message line", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 2,
        path: "src/[main].c",
        author: "a*lice",
        date: "2026-06-22T00:00:00.000000Z",
      }),
      logResponse({
        path: "src/[main].c",
        revision: 4,
        message: "\r\n  Fix *hover* [line](command:subversionr.bad) <img src=x>\r\nSecond line",
      }),
    );
    const provider = hoverProvider({
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                path: "src/[main].c",
                localStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    const hover = await provider.provideHover(textDocument("C:\\workspace\\SRC\\[MAIN].C"), { line: 1 }, cancellation());

    expect(historyClient.getBlame).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/[main].c",
      pegRevision: "base",
      startRevision: "r0",
      endRevision: "base",
      lineStart: 2,
      lineLimit: 1,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
      remote: anonymousSvnRemoteEnvelope(),
    }, { signal: expect.any(AbortSignal) });
    expect(historyClient.getLog).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/[main].c",
      startRevision: "r4",
      endRevision: "r4",
      limit: 1,
      discoverChangedPaths: false,
      strictNodeHistory: false,
      includeMergedRevisions: false,
      remote: anonymousSvnRemoteEnvelope(),
    }, { signal: expect.any(AbortSignal) });
    expect(hover).toEqual({
      contents: [
        {
          value:
            "**l10n:SVN Blame: src/\\[main\\]\\.c:2**\n\n" +
            "l10n:Revision r4\n\n" +
            "l10n:Author: a\\*lice\n\n" +
            "l10n:Date: 2026\\-06\\-22T00:00:00\\.000000Z\n\n" +
            "l10n:Log Message:\n\n" +
            "Fix \\*hover\\* \\[line\\]\\(command:subversionr\\.bad\\) \\<img src=x\\>",
        },
      ],
    });
  });

  it("returns current-line blame hover for a projected text-stable SVN file inside a changelist", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 3,
        path: "src/review.c",
      }),
      logResponse({
        path: "src/review.c",
        revision: 4,
        message: "Review changelist-safe line",
      }),
    );
    const provider = hoverProvider({
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

    const hover = await provider.provideHover(textDocument("C:\\workspace\\src\\review.c"), { line: 2 }, cancellation());

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
      remote: anonymousSvnRemoteEnvelope(),
    }, { signal: expect.any(AbortSignal) });
    expect(historyClient.getLog).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/review.c",
      startRevision: "r4",
      endRevision: "r4",
      limit: 1,
      discoverChangedPaths: false,
      strictNodeHistory: false,
      includeMergedRevisions: false,
      remote: anonymousSvnRemoteEnvelope(),
    }, { signal: expect.any(AbortSignal) });
    expect(hover?.contents[0]?.value).toContain("l10n:SVN Blame: src/review\\.c:3");
    expect(hover?.contents[0]?.value).toContain("Review changelist\\-safe line");
  });

  it("includes merged revisions in current-line blame hover requests when history settings enable them", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 2,
      }),
      logResponse({
        revision: 4,
        message: "Merged hover history",
      }),
    );
    const provider = hoverProvider({
      includeMergedRevisions: () => true,
      historyClient,
    });

    const hover = await provider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 1 }, cancellation());

    expect(historyClient.getBlame).toHaveBeenCalledWith(
      expect.objectContaining({
        includeMergedRevisions: true,
      }),
      { signal: expect.any(AbortSignal) },
    );
    expect(historyClient.getLog).toHaveBeenCalledWith(
      expect.objectContaining({
        includeMergedRevisions: true,
      }),
      { signal: expect.any(AbortSignal) },
    );
    expect(hover?.contents[0]?.value).toContain("Merged hover history");
  });

  it("does not request blame or log in untrusted workspaces", async () => {
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1 }), logResponse({ revision: 4 }));
    const provider = hoverProvider({
      workspaceTrusted: false,
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

    const hover = await provider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, cancellation());

    expect(hover).toBeUndefined();
    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(historyClient.getLog).not.toHaveBeenCalled();
  });

  it.each([
    ["missing", null],
    ["empty", ""],
    ["whitespace", " \r\n\t\n "],
  ])("returns a localized empty-log summary for %s log messages", async (_label, message) => {
    const provider = hoverProvider({
      historyClient: fakeHistoryClient(
        blameResponse({ lineStart: 1 }),
        logResponse({
          revision: 4,
          message,
        }),
      ),
    });

    const hover = await provider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, cancellation());

    expect(hover?.contents[0]?.value).toContain("l10n:Log Message:");
    expect(hover?.contents[0]?.value).toContain("l10n:No log message");
  });

  it("does not request blame when hover Lens is disabled or the file is outside open repositories", async () => {
    const getProjectedResource = vi.fn<SourceControlProjectionService["getProjectedResource"]>();
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1 }));
    const provider = hoverProvider({
      settings: lensSettings({ hover: false }),
      historyClient,
      sourceControlProjection: { getProjectedResource },
    });

    const hover = await provider.provideHover(textDocument("D:\\outside\\src\\main.c"), { line: 0 }, cancellation());

    expect(hover).toBeUndefined();
    expect(getProjectedResource).not.toHaveBeenCalled();
    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(historyClient.getLog).not.toHaveBeenCalled();
  });

  it.each([
    ["dirty editor", textDocument("C:\\workspace\\src\\main.c", { isDirty: true }), scmProjectedResource({ textStatus: "normal" })],
    ["text-modified resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ textStatus: "modified" })],
    ["added resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "added", nodeStatus: "added", textStatus: "normal" })],
    [
      "local-added resource with normal node and text status",
      textDocument("C:\\workspace\\src\\main.c"),
      scmProjectedResource({ localStatus: "added", nodeStatus: "normal", textStatus: "normal" }),
    ],
    [
      "replaced resource",
      textDocument("C:\\workspace\\src\\main.c"),
      scmProjectedResource({ localStatus: "replaced", nodeStatus: "replaced", textStatus: "normal" }),
    ],
    [
      "local-replaced resource with normal node and text status",
      textDocument("C:\\workspace\\src\\main.c"),
      scmProjectedResource({ localStatus: "replaced", nodeStatus: "normal", textStatus: "normal" }),
    ],
    [
      "obstructed resource",
      textDocument("C:\\workspace\\src\\main.c"),
      scmProjectedResource({ localStatus: "obstructed", nodeStatus: "obstructed", textStatus: "normal" }),
    ],
    [
      "local-obstructed resource with normal node and text status",
      textDocument("C:\\workspace\\src\\main.c"),
      scmProjectedResource({ localStatus: "obstructed", nodeStatus: "normal", textStatus: "normal" }),
    ],
    [
      "incomplete resource",
      textDocument("C:\\workspace\\src\\main.c"),
      scmProjectedResource({ localStatus: "incomplete", nodeStatus: "incomplete", textStatus: "normal" }),
    ],
    [
      "local-incomplete resource with normal node and text status",
      textDocument("C:\\workspace\\src\\main.c"),
      scmProjectedResource({ localStatus: "incomplete", nodeStatus: "normal", textStatus: "normal" }),
    ],
    [
      "conflicted resource",
      textDocument("C:\\workspace\\src\\main.c"),
      scmProjectedResource(
        { localStatus: "conflicted", nodeStatus: "conflicted", textStatus: "conflicted" },
        { groupId: "conflicts", contextValue: "subversionr.conflicted" },
      ),
    ],
    [
      "local-conflicted resource with normal node and text status",
      textDocument("C:\\workspace\\src\\main.c"),
      scmProjectedResource({ localStatus: "conflicted", nodeStatus: "normal", textStatus: "normal" }),
    ],
  ])("does not request blame for %s", async (_label, document, resource) => {
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1 }));
    const provider = hoverProvider({
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [resource],
          }),
        ],
      ]),
    });

    const hover = await provider.provideHover(document, { line: 0 }, cancellation());

    expect(hover).toBeUndefined();
    expect(historyClient.getBlame).not.toHaveBeenCalled();
  });

  it("does not return a hover when cancellation happens before or after the blame request", async () => {
    const afterRequest = cancellation();
    const historyClient = {
      getBlame: vi.fn(async () => {
        afterRequest.isCancellationRequested = true;
        return blameResponse({ lineStart: 1 });
      }),
      getLog: vi.fn(async () => logResponse({ revision: 4 })),
    };
    const provider = hoverProvider({ historyClient });

    await expect(provider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, cancellation(true))).resolves.toBeUndefined();
    await expect(provider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, afterRequest)).resolves.toBeUndefined();

    expect(historyClient.getBlame).toHaveBeenCalledTimes(1);
    expect(historyClient.getLog).not.toHaveBeenCalled();
  });

  it("does not return a hover when cancellation happens after the log request", async () => {
    const afterLog = cancellation();
    const historyClient = {
      getBlame: vi.fn(async () => blameResponse({ lineStart: 1 })),
      getLog: vi.fn(async () => {
        afterLog.isCancellationRequested = true;
        return logResponse({ revision: 4, message: "Fix hover" });
      }),
    };
    const provider = hoverProvider({ historyClient });

    await expect(
      provider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, afterLog),
    ).resolves.toBeUndefined();

    expect(historyClient.getBlame).toHaveBeenCalledTimes(1);
    expect(historyClient.getLog).toHaveBeenCalledTimes(1);
  });

  it.each([
    ["local-change", { revision: 4, localChange: true }],
    ["unknown-revision", { revision: null, localChange: false }],
  ] as const)("hides %s blame rows without requesting log summaries", async (_label, blameOptions) => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 1,
        revision: blameOptions.revision,
        localChange: blameOptions.localChange,
      }),
    );
    const provider = hoverProvider({
      historyClient,
    });

    const hover = await provider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, cancellation());

    expect(hover).toBeUndefined();
    expect(historyClient.getLog).not.toHaveBeenCalled();
  });

  it("returns no hover when projection lookup, blame, or log request fails", async () => {
    const projectionFailureProvider = hoverProvider({
      sourceControlProjection: {
        getProjectedResource: () => {
          throw new Error("projection unavailable");
        },
      },
    });
    const blameFailureProvider = hoverProvider({
      historyClient: {
        getBlame: vi.fn(async () => {
          throw new Error("backend unavailable");
        }),
        getLog: vi.fn(async () => logResponse({ revision: 4 })),
      },
    });
    const logFailureProvider = hoverProvider({
      historyClient: {
        getBlame: vi.fn(async () => blameResponse({ lineStart: 1 })),
        getLog: vi.fn(async () => {
          throw new Error("log unavailable");
        }),
      },
    });

    await expect(
      projectionFailureProvider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, cancellation()),
    ).resolves.toBeUndefined();
    await expect(
      blameFailureProvider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, cancellation()),
    ).resolves.toBeUndefined();
    await expect(
      logFailureProvider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, cancellation()),
    ).resolves.toBeUndefined();
  });

  it("returns no hover when the single-revision log entry is missing or mismatched", async () => {
    for (const log of [
      logResponse({ revision: 4, entries: [] }),
      logResponse({ revision: 5, message: "Different revision" }),
    ]) {
      const provider = hoverProvider({
        historyClient: fakeHistoryClient(blameResponse({ lineStart: 1, revision: 4 }), log),
      });

      await expect(
        provider.provideHover(textDocument("C:\\workspace\\src\\main.c"), { line: 0 }, cancellation()),
      ).resolves.toBeUndefined();
    }
  });
});

function hoverProvider(options: {
  settings?: LensSettings;
  includeMergedRevisions?: () => boolean;
  historyClient?: HistoryBlameClient & HistoryLogClient;
  sessions?: RepositorySession[];
  projections?: Map<string, ScmRepositoryProjection | undefined>;
  sourceControlProjection?: Pick<SourceControlProjectionService, "getProjectedResource">;
  workspaceTrusted?: boolean;
} = {}): CurrentLineBlameHoverProvider<TestHover, TestMarkdownString> {
  const projections = options.projections ?? new Map([["repo-uuid:C:/workspace", scmProjection()]]);
  return new CurrentLineBlameHoverProvider<TestHover, TestMarkdownString>({
    settings: () => options.settings ?? lensSettings(),
    includeMergedRevisions: options.includeMergedRevisions ?? (() => false),
    historyClient: options.historyClient ?? fakeHistoryClient(blameResponse({ lineStart: 1 })),
    createRemoteEnvelope: async () => anonymousSvnRemoteEnvelope(),
    sessionService: fakeSessionService(options.sessions ?? [repositorySession()]),
    sourceControlProjection: options.sourceControlProjection ?? fakeSourceControlProjection(projections),
    workspaceTrusted: () => options.workspaceTrusted ?? true,
    api: {
      createMarkdownString: (value) => ({ value }),
      createHover: (contents) => ({ contents }),
      localize: localizeForTest,
    },
  });
}

function fakeHistoryClient(
  blame: HistoryBlame,
  log: HistoryLog = logResponse({ revision: 4 }),
): HistoryBlameClient & HistoryLogClient & {
  getBlame: ReturnType<typeof vi.fn<(request: HistoryBlameRequest) => Promise<HistoryBlame>>>;
  getLog: ReturnType<typeof vi.fn<(request: HistoryLogRequest) => Promise<HistoryLog>>>;
} {
  return {
    getBlame: vi.fn(async () => blame),
    getLog: vi.fn(async () => log),
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
    textStatus: overrides.textStatus ?? "normal",
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
    conflictArtifacts: overrides.conflictArtifacts ?? [],
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

function textDocument(
  fsPath: string,
  options: { scheme?: string; lineCount?: number; isDirty?: boolean } = {},
): CurrentLineBlameHoverTextDocument {
  return {
    uri: {
      scheme: options.scheme ?? "file",
      fsPath,
    },
    lineCount: options.lineCount ?? 20,
    isDirty: options.isDirty ?? false,
  };
}

function cancellation(isCancellationRequested = false): CurrentLineBlameHoverCancellationToken {
  return {
    isCancellationRequested,
    onCancellationRequested: vi.fn(() => ({ dispose: vi.fn() })),
  };
}

function blameResponse(options: {
  lineStart: number;
  path?: string;
  revision?: number | null;
  author?: string | null;
  date?: string | null;
  localChange?: boolean;
}): HistoryBlame {
  const line = Buffer.from("test", "utf8");
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
        revision: options.revision === undefined ? 4 : options.revision,
        author: options.author === undefined ? "alice" : options.author,
        date: options.date === undefined ? "2026-06-22T00:00:00.000000Z" : options.date,
        mergedRevision: null,
        mergedAuthor: null,
        mergedDate: null,
        mergedPath: null,
        lineBase64: line.toString("base64"),
        byteLength: line.byteLength,
        localChange: options.localChange ?? false,
      },
    ],
    source: "libsvn-blame",
  };
}

function logResponse(options: {
  path?: string;
  revision: number;
  message?: string | null;
  entries?: HistoryLog["entries"];
}): HistoryLog {
  return {
    repositoryId: "repo-uuid:C:/workspace",
    epoch: 7,
    path: options.path ?? "src/main.c",
    startRevision: `r${options.revision}` as HistoryLog["startRevision"],
    endRevision: `r${options.revision}` as HistoryLog["endRevision"],
    limit: 1,
    entries: options.entries ?? [
      {
        revision: options.revision,
        author: "alice",
        date: "2026-06-22T00:00:00.000000Z",
        message: options.message === undefined ? "Fix hover" : options.message,
        changedPaths: [],
        hasChildren: false,
        nonInheritable: false,
        subtractiveMerge: false,
      },
    ],
    source: "libsvn-log",
  };
}

function localizeForTest(message: string, ...args: unknown[]): string {
  return `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`;
}

interface CurrentLineBlameHoverTextDocument {
  uri: {
    scheme: string;
    fsPath: string;
  };
  lineCount: number;
  isDirty: boolean;
}

interface CurrentLineBlameHoverCancellationToken {
  isCancellationRequested: boolean;
  onCancellationRequested(listener: () => void): { dispose(): void };
}

interface TestMarkdownString {
  value: string;
}

interface TestHover {
  contents: readonly TestMarkdownString[];
}

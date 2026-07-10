import { Buffer } from "node:buffer";
import { describe, expect, it, vi } from "vitest";
import { SymbolHistoryCodeLensProvider } from "../src/lens/symbolHistoryCodeLensProvider";
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

describe("SymbolHistoryCodeLensProvider", () => {
  it("provides unresolved symbol lenses for projected text-stable SVN files without requesting blame", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 2,
        lineLimit: 3,
      }),
    );
    const executeDocumentSymbols = vi.fn(async () => [
      documentSymbol("outer", range(1, 0, 3, 1), range(1, 9, 1, 14), [
        documentSymbol("inner", range(2, 2, 2, 15), range(2, 11, 2, 16)),
      ]),
    ]);
    const provider = symbolHistoryProvider({
      historyClient,
      executeDocumentSymbols,
    });

    const lenses = await provider.provideCodeLenses(textDocument("C:\\workspace\\SRC\\MAIN.C"), cancellation());

    expect(executeDocumentSymbols).toHaveBeenCalledWith({ scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" });
    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(lenses.map((lens) => lens.command)).toEqual([undefined, undefined]);
    expect(lenses.map((lens) => lens.range)).toEqual([
      { range: { startLine: 1, startCharacter: 0, endLine: 1, endCharacter: 0 } },
      { range: { startLine: 2, startCharacter: 0, endLine: 2, endCharacter: 0 } },
    ].map((lens) => lens.range));
  });

  it("resolves a visible symbol lens with BASE blame revision, author, and revision counts", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 2,
        lineLimit: 3,
        lines: [
          blameLine(2, 5, "alice"),
          blameLine(3, 7, "bob"),
          blameLine(4, 7, "alice"),
        ],
      }),
    );
    const provider = symbolHistoryProvider({
      historyClient,
      executeDocumentSymbols: async () => [documentSymbol("outer", range(1, 0, 3, 1), range(1, 9, 1, 14))],
    });
    const [lens] = await provider.provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"), cancellation());

    const resolved = await provider.resolveCodeLens(lens!, cancellation());

    expect(historyClient.getBlame).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      pegRevision: "base",
      startRevision: "r0",
      endRevision: "base",
      lineStart: 2,
      lineLimit: 3,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
    });
    expect(resolved.command).toEqual({
      command: "subversionr.showBlame",
      title: "SVN r7 - Authors 2, Revisions 2",
      arguments: [
        {
          contextValue: "subversionr.changedFile",
          subversionrResourceKind: "file",
          subversionrProjectionGeneration: 11,
          resourceUri: { scheme: "file", fsPath: "C:\\workspace\\src\\main.c" },
        },
      ],
    });
  });

  it("includes merged revisions in symbol history blame requests when history settings enable them", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 2,
        lineLimit: 1,
      }),
    );
    const provider = symbolHistoryProvider({
      historyClient,
      includeMergedRevisions: true,
      executeDocumentSymbols: async () => [documentSymbol("outer", range(1, 0, 1, 1), range(1, 0, 1, 1))],
    });
    const [lens] = await provider.provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"), cancellation());

    await provider.resolveCodeLens(lens!, cancellation());

    expect(historyClient.getBlame).toHaveBeenCalledWith(
      expect.objectContaining({
        includeMergedRevisions: true,
      }),
    );
  });

  it("provides and resolves symbol history lenses for a text-stable SVN file inside a changelist", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        path: "src/review.c",
        lineStart: 4,
        lineLimit: 2,
        lines: [blameLine(4, 8, "alice"), blameLine(5, 9, "bob")],
      }),
    );
    const executeDocumentSymbols = vi.fn(async () => [
      documentSymbol("reviewedSymbol", range(3, 0, 4, 1), range(3, 2, 3, 16)),
    ]);
    const provider = symbolHistoryProvider({
      historyClient,
      executeDocumentSymbols,
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

    const [lens] = await provider.provideCodeLenses(textDocument("C:\\workspace\\src\\review.c"), cancellation());

    expect(executeDocumentSymbols).toHaveBeenCalledWith({ scheme: "file", fsPath: "C:\\workspace\\src\\review.c" });
    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(lens?.range).toEqual({ startLine: 3, startCharacter: 0, endLine: 3, endCharacter: 0 });

    const resolved = await provider.resolveCodeLens(lens!, cancellation());

    expect(historyClient.getBlame).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/review.c",
      pegRevision: "base",
      startRevision: "r0",
      endRevision: "base",
      lineStart: 4,
      lineLimit: 2,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
    });
    expect(resolved.command).toEqual({
      command: "subversionr.showBlame",
      title: "SVN r9 - Authors 2, Revisions 2",
      arguments: [
        {
          contextValue: "subversionr.changedFile",
          subversionrResourceKind: "file",
          subversionrProjectionGeneration: 11,
          resourceUri: { scheme: "file", fsPath: "C:\\workspace\\src\\review.c" },
        },
      ],
    });
  });

  it("does not provide or resolve symbol history lenses in untrusted workspaces", async () => {
    let workspaceTrusted = false;
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 2, lineLimit: 1 }));
    const executeDocumentSymbols = vi.fn(async () => [
      documentSymbol("outer", range(1, 0, 1, 1), range(1, 0, 1, 1)),
    ]);
    const provider = symbolHistoryProvider({
      workspaceTrusted: () => workspaceTrusted,
      historyClient,
      executeDocumentSymbols,
    });

    await expect(provider.provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"), cancellation())).resolves.toEqual([]);
    expect(executeDocumentSymbols).not.toHaveBeenCalled();
    expect(historyClient.getBlame).not.toHaveBeenCalled();

    workspaceTrusted = true;
    const [lens] = await provider.provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"), cancellation());
    workspaceTrusted = false;

    const resolved = await provider.resolveCodeLens(lens!, cancellation());

    expect(resolved.command).toBeUndefined();
    expect(historyClient.getBlame).not.toHaveBeenCalled();
  });

  it("supports SymbolInformation ranges from the current document", async () => {
    const provider = symbolHistoryProvider({
      executeDocumentSymbols: async () => [
        symbolInformation("from-current", textDocument("C:\\workspace\\src\\main.c").uri, range(4, 0, 6, 1)),
        symbolInformation("from-other", textDocument("C:\\other\\src\\main.c").uri, range(7, 0, 7, 1)),
      ],
    });

    const lenses = await provider.provideCodeLenses(textDocument("C:\\workspace\\src\\main.c", { lineCount: 20 }), cancellation());

    expect(lenses.map((lens) => lens.range)).toEqual([
      { startLine: 4, startCharacter: 0, endLine: 4, endCharacter: 0 },
    ]);
  });

  it("does not provide lenses for missing symbols, invalid ranges, or oversized symbol ranges", async () => {
    await expect(
      symbolHistoryProvider({
        executeDocumentSymbols: async () => undefined,
      }).provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"), cancellation()),
    ).resolves.toEqual([]);
    await expect(
      symbolHistoryProvider({
        executeDocumentSymbols: async () => [
          documentSymbol("invalid", range(4, 0, 3, 1), range(4, 0, 4, 1)),
          documentSymbol("outside", range(19, 0, 20, 1), range(19, 0, 19, 1)),
        ],
      }).provideCodeLenses(textDocument("C:\\workspace\\src\\main.c", { lineCount: 20 }), cancellation()),
    ).resolves.toEqual([]);
    await expect(
      symbolHistoryProvider({
        executeDocumentSymbols: async () => [
          documentSymbol("large", range(0, 0, 5000, 1), range(0, 0, 0, 1)),
        ],
      }).provideCodeLenses(textDocument("C:\\workspace\\src\\main.c", { lineCount: 6000 }), cancellation()),
    ).resolves.toEqual([]);
  });

  it("does not query symbols when disabled, outside open repositories, dirty, oversized, or unsafe", async () => {
    const executeDocumentSymbols = vi.fn(async () => [documentSymbol("outer", range(1, 0, 1, 1), range(1, 0, 1, 1))]);

    for (const [label, options] of [
      ["disabled", { settings: lensSettings({ symbols: false }) }],
      ["outside", { document: textDocument("D:\\outside\\src\\main.c") }],
      ["dirty", { document: textDocument("C:\\workspace\\src\\main.c", { isDirty: true }) }],
      ["oversized", { document: textDocument("C:\\workspace\\src\\main.c", { lineCount: 20001 }) }],
      [
        "local-added",
        {
          resource: scmProjectedResource({
            localStatus: "added",
            nodeStatus: "normal",
            textStatus: "normal",
          }),
        },
      ],
      [
        "node-added",
        {
          resource: scmProjectedResource({
            localStatus: "modified",
            nodeStatus: "added",
            textStatus: "normal",
          }),
        },
      ],
      [
        "text-modified",
        {
          resource: scmProjectedResource({
            localStatus: "modified",
            nodeStatus: "normal",
            textStatus: "modified",
          }),
        },
      ],
      [
        "deleted",
        {
          resource: scmProjectedResource({
            localStatus: "deleted",
            nodeStatus: "deleted",
            textStatus: "deleted",
          }),
        },
      ],
      [
        "missing",
        {
          resource: scmProjectedResource({
            localStatus: "missing",
            nodeStatus: "missing",
            textStatus: "missing",
          }),
        },
      ],
      ["external", { resource: scmProjectedResource({ external: true }) }],
      [
        "directory",
        {
          resource: scmProjectedResource(
            { kind: "dir" },
            { contextValue: "subversionr.changedDirectory" },
          ),
        },
      ],
      [
        "incoming",
        {
          resource: scmProjectedResource(
            { remoteStatus: "modified" },
            { source: "remote", groupId: "incoming", contextValue: "subversionr.incoming" },
          ),
        },
      ],
      [
        "ignored",
        {
          resource: scmProjectedResource(
            { localStatus: "ignored" },
            { groupId: "ignored", contextValue: "subversionr.ignored" },
          ),
        },
      ],
      [
        "conflict-group",
        {
          resource: scmProjectedResource(
            { localStatus: "conflicted", nodeStatus: "conflicted", textStatus: "conflicted" },
            { groupId: "conflicts", contextValue: "subversionr.conflicted" },
          ),
        },
      ],
    ] as const) {
      const provider = symbolHistoryProvider({
        settings: options.settings,
        executeDocumentSymbols,
        projections: options.resource
          ? new Map([
              [
                "repo-uuid:C:/workspace",
                scmProjection({
                  resources: [options.resource],
                }),
              ],
            ])
          : undefined,
      });

      const lenses = await provider.provideCodeLenses(options.document ?? textDocument("C:\\workspace\\src\\main.c"), cancellation());

      expect(lenses, label).toEqual([]);
    }
    expect(executeDocumentSymbols).not.toHaveBeenCalled();
  });

  it("does not resolve a command when blame is cancelled, incomplete, local-only, or fails", async () => {
    const lens = (
      await symbolHistoryProvider({
        executeDocumentSymbols: async () => [documentSymbol("outer", range(1, 0, 1, 1), range(1, 0, 1, 1))],
      }).provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"), cancellation())
    )[0]!;

    await expect(
      symbolHistoryProvider({
        historyClient: fakeHistoryClient(blameResponse({ lineStart: 2, lineLimit: 1 })),
      }).resolveCodeLens(lens, cancellation(true)),
    ).resolves.toEqual(lens);
    await expect(
      providerWithBlame(
        blameResponse({
          lineStart: 2,
          lineLimit: 1,
          lines: [blameLine(2, 5, "alice")],
          hasMore: true,
        }),
      ).resolveCodeLens(lens, cancellation()),
    ).resolves.toEqual(lens);
    await expect(
      providerWithBlame(blameResponse({ lineStart: 2, lineLimit: 2, lines: [blameLine(2, 5, "alice")] })).resolveCodeLens(
        lens,
        cancellation(),
      ),
    ).resolves.toEqual(lens);
    await expect(
      providerWithBlame(
        blameResponse({
          lineStart: 2,
          lineLimit: 1,
          lines: [blameLine(2, null, "alice", { localChange: true })],
        }),
      ).resolveCodeLens(lens, cancellation()),
    ).resolves.toEqual(lens);
    await expect(
      symbolHistoryProvider({
        historyClient: {
          getBlame: vi.fn(async () => {
            throw new Error("backend unavailable");
          }),
        },
      }).resolveCodeLens(lens, cancellation()),
    ).resolves.toEqual(lens);
  });
});

function providerWithBlame(blame: HistoryBlame): SymbolHistoryCodeLensProvider<TestCodeLens> {
  return symbolHistoryProvider({ historyClient: fakeHistoryClient(blame) });
}

function symbolHistoryProvider(options: {
  settings?: LensSettings;
  includeMergedRevisions?: boolean;
  historyClient?: HistoryBlameClient;
  sessions?: RepositorySession[];
  projections?: Map<string, ScmRepositoryProjection | undefined>;
  sourceControlProjection?: Pick<SourceControlProjectionService, "getProjectedResource">;
  executeDocumentSymbols?: (uri: TestUri) => Promise<TestSymbol[] | undefined>;
  workspaceTrusted?: () => boolean;
} = {}): SymbolHistoryCodeLensProvider<TestCodeLens> {
  const projections = options.projections ?? new Map([["repo-uuid:C:/workspace", scmProjection()]]);
  return new SymbolHistoryCodeLensProvider<TestCodeLens>({
    settings: () => options.settings ?? lensSettings({ symbols: true }),
    includeMergedRevisions: () => options.includeMergedRevisions ?? false,
    historyClient: options.historyClient ?? fakeHistoryClient(blameResponse({ lineStart: 2, lineLimit: 1 })),
    sessionService: fakeSessionService(options.sessions ?? [repositorySession()]),
    sourceControlProjection: options.sourceControlProjection ?? fakeSourceControlProjection(projections),
    workspaceTrusted: options.workspaceTrusted ?? (() => true),
    api: {
      createEventEmitter: () => fakeEventEmitter(),
      createRange: (startLine, startCharacter, endLine, endCharacter) => ({
        startLine,
        startCharacter,
        endLine,
        endCharacter,
      }),
      createCodeLens: (range) => ({ range }),
      executeDocumentSymbols: options.executeDocumentSymbols ?? (async () => []),
      localize: (message, ...args) =>
        args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message),
    },
  });
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

function fakeEventEmitter() {
  return {
    event: vi.fn(),
    fire: vi.fn(),
    dispose: vi.fn(),
  };
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
): TestTextDocument {
  return {
    uri: {
      scheme: options.scheme ?? "file",
      fsPath,
    },
    lineCount: options.lineCount ?? 20,
    isDirty: options.isDirty ?? false,
  };
}

function documentSymbol(
  name: string,
  symbolRange: TestRange,
  selectionRange: TestRange,
  children: TestDocumentSymbol[] = [],
): TestDocumentSymbol {
  return {
    name,
    range: symbolRange,
    selectionRange,
    children,
  };
}

function symbolInformation(name: string, uri: TestUri, symbolRange: TestRange): TestSymbolInformation {
  return {
    name,
    location: {
      uri,
      range: symbolRange,
    },
  };
}

function range(startLine: number, startCharacter: number, endLine: number, endCharacter: number): TestRange {
  return {
    start: { line: startLine, character: startCharacter },
    end: { line: endLine, character: endCharacter },
  };
}

function cancellation(isCancellationRequested = false) {
  return { isCancellationRequested };
}

function blameResponse(options: {
  lineStart: number;
  lineLimit: number;
  path?: string;
  lines?: HistoryBlame["lines"];
  hasMore?: boolean;
}): HistoryBlame {
  return {
    repositoryId: "repo-uuid:C:/workspace",
    epoch: 7,
    path: options.path ?? "src/main.c",
    pegRevision: "base",
    startRevision: "r0" as HistoryBlame["startRevision"],
    endRevision: "base",
    resolvedStartRevision: 1,
    resolvedEndRevision: 7,
    lineStart: options.lineStart,
    lineLimit: options.lineLimit,
    ignoreWhitespace: "none",
    ignoreEolStyle: false,
    ignoreMimeType: false,
    includeMergedRevisions: false,
    hasMore: options.hasMore ?? false,
    lines:
      options.lines ??
      Array.from({ length: options.lineLimit }, (_value, index) =>
        blameLine(options.lineStart + index, 4, "alice"),
      ),
    source: "libsvn-blame",
  };
}

function blameLine(
  lineNumber: number,
  revision: number | null,
  author: string | null,
  overrides: Partial<HistoryBlame["lines"][number]> = {},
): HistoryBlame["lines"][number] {
  const line = Buffer.from("test", "utf8");
  return {
    lineNumber,
    revision,
    author,
    date: "2026-06-22T00:00:00.000000Z",
    mergedRevision: null,
    mergedAuthor: null,
    mergedDate: null,
    mergedPath: null,
    lineBase64: line.toString("base64"),
    byteLength: line.byteLength,
    localChange: false,
    ...overrides,
  };
}

interface TestUri {
  scheme: string;
  fsPath: string;
}

interface TestTextDocument {
  uri: TestUri;
  lineCount: number;
  isDirty: boolean;
}

interface TestPosition {
  line: number;
  character: number;
}

interface TestRange {
  start: TestPosition;
  end: TestPosition;
}

interface TestDocumentSymbol {
  name: string;
  range: TestRange;
  selectionRange: TestRange;
  children: TestDocumentSymbol[];
}

interface TestSymbolInformation {
  name: string;
  location: {
    uri: TestUri;
    range: TestRange;
  };
}

type TestSymbol = TestDocumentSymbol | TestSymbolInformation;

interface TestCodeLens {
  range: unknown;
  command?: {
    command: string;
    title: string;
    arguments?: unknown[];
  };
}

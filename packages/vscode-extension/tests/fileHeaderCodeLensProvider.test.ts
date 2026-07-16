import { describe, expect, it, vi } from "vitest";
import { FileHeaderCodeLensProvider } from "../src/lens/fileHeaderCodeLensProvider";
import type { LensSettings } from "../src/lens/lensSettings";
import type { RepositorySession, RepositorySessionService } from "../src/repository/repositorySessionService";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type {
  ScmProjectedResource,
  ScmProjectedResourceLookup,
  ScmRepositoryProjection,
} from "../src/scm/sourceControlResourceStore";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";

describe("FileHeaderCodeLensProvider", () => {
  it("provides unresolved file-header lenses for a projected local base-diffable text file", () => {
    const provider = fileHeaderProvider();

    const lenses = provider.provideCodeLenses(textDocument("C:\\workspace\\SRC\\MAIN.C"));

    expect(lenses).toHaveLength(7);
    expect(lenses.map((lens) => lens.command)).toEqual([
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
    ]);
    expect(lenses.map((lens) => lens.range)).toEqual([
      { startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0 },
      { startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0 },
      { startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0 },
      { startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0 },
      { startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0 },
      { startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0 },
      { startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0 },
    ]);
  });

  it("resolves file-header lenses to summary, PREV/BASE/HEAD compare, file history, blame, and repository log commands", async () => {
    const provider = fileHeaderProvider();
    const lenses = provider.provideCodeLenses(textDocument("C:\\workspace\\SRC\\MAIN.C"));

    const resolved = [];
    for (const lens of lenses) {
      resolved.push(await provider.resolveCodeLens(lens, { isCancellationRequested: false }));
    }

    expect(resolved.map((lens) => lens.command)).toEqual([
      {
        command: "subversionr.showFileHistory",
        title: "SVN r3 by alice on 2026-06-22",
        arguments: [
          {
            contextValue: "subversionr.changedFile",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" },
          },
        ],
      },
      {
        command: "subversionr.diffWithPrevious",
        title: "Compare PREV",
        arguments: [
          {
            contextValue: "subversionr.changedFile",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" },
          },
        ],
      },
      {
        command: "subversionr.diffWithBase",
        title: "Compare BASE",
        arguments: [
          {
            contextValue: "subversionr.changedFile.baseDiffable",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" },
          },
        ],
      },
      {
        command: "subversionr.diffWithHead",
        title: "Compare HEAD",
        arguments: [
          {
            contextValue: "subversionr.changedFile.baseDiffable",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" },
          },
        ],
      },
      {
        command: "subversionr.showFileHistory",
        title: "File History",
        arguments: [
          {
            contextValue: "subversionr.changedFile",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" },
          },
        ],
      },
      {
        command: "subversionr.showBlame",
        title: "Blame",
        arguments: [
          {
            contextValue: "subversionr.changedFile",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" },
          },
        ],
      },
      {
        command: "subversionr.showRepositoryLog",
        title: "Open Log",
        arguments: [
          {
            kind: "subversionr.repositoryHistoryTarget",
            repositoryId: "repo-uuid:C:/workspace",
            epoch: 7,
          },
        ],
      },
    ]);
  });

  it("provides and resolves file-header lenses for a projected local base-diffable text file inside a changelist", async () => {
    const provider = fileHeaderProvider({
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource(
                {
                  path: "src/review.c",
                  changelist: "review",
                  changedRevision: 4,
                  changedAuthor: "bob",
                  changedDate: "2026-07-04T15:00:00Z",
                  localStatus: "modified",
                  textStatus: "modified",
                  propertyStatus: "normal",
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

    const lenses = provider.provideCodeLenses(textDocument("C:\\workspace\\src\\review.c"));

    expect(lenses).toHaveLength(7);
    const resolved = [];
    for (const lens of lenses) {
      resolved.push(await provider.resolveCodeLens(lens, { isCancellationRequested: false }));
    }

    expect(resolved.map((lens) => lens.command)).toEqual([
      {
        command: "subversionr.showFileHistory",
        title: "SVN r4 by bob on 2026-07-04",
        arguments: [
          {
            contextValue: "subversionr.changedFile",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\src\\review.c" },
          },
        ],
      },
      {
        command: "subversionr.diffWithPrevious",
        title: "Compare PREV",
        arguments: [
          {
            contextValue: "subversionr.changedFile",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\src\\review.c" },
          },
        ],
      },
      {
        command: "subversionr.diffWithBase",
        title: "Compare BASE",
        arguments: [
          {
            contextValue: "subversionr.changedFile.baseDiffable",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\src\\review.c" },
          },
        ],
      },
      {
        command: "subversionr.diffWithHead",
        title: "Compare HEAD",
        arguments: [
          {
            contextValue: "subversionr.changedFile.baseDiffable",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\src\\review.c" },
          },
        ],
      },
      {
        command: "subversionr.showFileHistory",
        title: "File History",
        arguments: [
          {
            contextValue: "subversionr.changedFile",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\src\\review.c" },
          },
        ],
      },
      {
        command: "subversionr.showBlame",
        title: "Blame",
        arguments: [
          {
            contextValue: "subversionr.changedFile",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { scheme: "file", fsPath: "C:\\workspace\\src\\review.c" },
          },
        ],
      },
      {
        command: "subversionr.showRepositoryLog",
        title: "Open Log",
        arguments: [
          {
            kind: "subversionr.repositoryHistoryTarget",
            repositoryId: "repo-uuid:C:/workspace",
            epoch: 7,
          },
        ],
      },
    ]);
  });

  it("only exposes BASE comparison from file-header lenses in untrusted workspaces", async () => {
    const provider = fileHeaderProvider({ workspaceTrusted: false });
    const lenses = provider.provideCodeLenses(textDocument("C:\\workspace\\SRC\\MAIN.C"));

    expect(lenses).toHaveLength(1);
    const resolved = await provider.resolveCodeLens(lenses[0]!, { isCancellationRequested: false });

    expect(resolved.command).toEqual({
      command: "subversionr.diffWithBase",
      title: "Compare BASE",
      arguments: [
        {
          contextValue: "subversionr.changedFile.baseDiffable",
          subversionrResourceKind: "file",
          subversionrProjectionGeneration: 11,
          resourceUri: { scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" },
        },
      ],
    });
  });

  it("uses the most specific open repository and projection for nested working copies", async () => {
    const provider = fileHeaderProvider({
      sessions: [
        repositorySession({ repositoryId: "repo-uuid:C:/workspace", workingCopyRoot: "C:\\workspace" }),
        repositorySession({
          repositoryId: "repo-uuid:C:/workspace/nested",
          workingCopyRoot: "C:\\workspace\\nested",
        }),
      ],
      projections: new Map([
        ["repo-uuid:C:/workspace", scmProjection({ repositoryId: "repo-uuid:C:/workspace" })],
        [
          "repo-uuid:C:/workspace/nested",
          scmProjection({
            repositoryId: "repo-uuid:C:/workspace/nested",
            workingCopyRoot: "C:/workspace/nested",
            resources: [scmProjectedResource({ path: "src/nested.c", changedRevision: 9, changedAuthor: "bob" })],
          }),
        ],
      ]),
    });

    const [summary] = provider.provideCodeLenses(textDocument("C:\\workspace\\nested\\src\\nested.c"));
    const resolved = await provider.resolveCodeLens(summary!, { isCancellationRequested: false });

    expect(resolved.command).toEqual({
      command: "subversionr.showFileHistory",
      title: "SVN r9 by bob on 2026-06-22",
      arguments: [
        {
          contextValue: "subversionr.changedFile",
          subversionrResourceKind: "file",
          subversionrProjectionGeneration: 11,
          resourceUri: { scheme: "file", fsPath: "C:\\workspace\\nested\\src\\nested.c" },
        },
      ],
    });
  });

  it("exposes BASE and HEAD compare lenses for the libsvn property-only file shape", async () => {
    const provider = fileHeaderProvider({
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                nodeStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    const resolved = [];
    for (const lens of provider.provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"))) {
      resolved.push(await provider.resolveCodeLens(lens, { isCancellationRequested: false }));
    }

    expect(resolved.map((lens) => lens.command?.command)).toEqual([
      "subversionr.showFileHistory",
      "subversionr.diffWithPrevious",
      "subversionr.diffWithBase",
      "subversionr.diffWithHead",
      "subversionr.showFileHistory",
      "subversionr.showBlame",
      "subversionr.showRepositoryLog",
    ]);
  });

  it.each([
    [
      "conflicted file",
      scmProjectedResource(
        { localStatus: "conflicted", nodeStatus: "conflicted", textStatus: "conflicted" },
        { groupId: "conflicts", contextValue: "subversionr.conflicted" },
      ),
    ],
  ])("does not expose BASE/HEAD compare lenses for %s", async (_label, resource) => {
    const provider = fileHeaderProvider({
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [resource],
          }),
        ],
      ]),
    });

    const lenses = provider.provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"));
    const resolved = [];
    for (const lens of lenses) {
      resolved.push(await provider.resolveCodeLens(lens, { isCancellationRequested: false }));
    }

    expect(resolved).toHaveLength(5);
    expect(resolved.map((lens) => lens.command?.command)).toEqual([
      "subversionr.showFileHistory",
      "subversionr.diffWithPrevious",
      "subversionr.showFileHistory",
      "subversionr.showBlame",
      "subversionr.showRepositoryLog",
    ]);
  });

  it("does not expose Compare PREV when the projected file has no previous revision candidate", async () => {
    const provider = fileHeaderProvider({
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [scmProjectedResource({ changedRevision: 0 })],
          }),
        ],
      ]),
    });

    const resolved = [];
    for (const lens of provider.provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"))) {
      resolved.push(await provider.resolveCodeLens(lens, { isCancellationRequested: false }));
    }

    expect(resolved.map((lens) => lens.command?.command)).toEqual([
      "subversionr.showFileHistory",
      "subversionr.diffWithBase",
      "subversionr.diffWithHead",
      "subversionr.showFileHistory",
      "subversionr.showBlame",
      "subversionr.showRepositoryLog",
    ]);
  });

  it("checks the file path against open sessions before requesting a projected resource", () => {
    const getProjectedResource = vi.fn<SourceControlProjectionService["getProjectedResource"]>();
    const provider = fileHeaderProvider({
      sessions: [repositorySession()],
      sourceControlProjection: { getProjectedResource },
    });

    expect(provider.provideCodeLenses(textDocument("C:\\other\\src\\main.c"))).toEqual([]);
    expect(getProjectedResource).not.toHaveBeenCalled();
  });

  it("does not provide lenses when disabled, file-header lenses are off, or the file is over the threshold", () => {
    expect(fileHeaderProvider({ settings: lensSettings({ enabled: false }) }).provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"))).toEqual([]);
    expect(fileHeaderProvider({ settings: lensSettings({ fileHeader: false }) }).provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"))).toEqual([]);
    expect(fileHeaderProvider({ settings: lensSettings({ maxFileLines: 10 }) }).provideCodeLenses(textDocument("C:\\workspace\\src\\main.c", 11))).toEqual([]);
  });

  it.each([
    ["untitled scheme", textDocument("C:\\workspace\\src\\main.c", 1, "untitled")],
    ["outside working copy", textDocument("C:\\other\\src\\main.c")],
    ["working-copy root", textDocument("C:\\workspace")],
  ])("does not provide lenses for %s", (_label, document) => {
    expect(fileHeaderProvider().provideCodeLenses(document)).toEqual([]);
  });

  it.each([
    ["unversioned", scmProjectedResource({ localStatus: "unversioned" }, { groupId: "unversioned", contextValue: "subversionr.unversioned" })],
    ["incoming", scmProjectedResource({ remoteStatus: "modified" }, { source: "remote", groupId: "incoming", contextValue: "subversionr.incoming" })],
    ["external", scmProjectedResource({ external: true })],
    ["ignored", scmProjectedResource({ localStatus: "ignored" }, { groupId: "ignored", contextValue: "subversionr.ignored" })],
    ["directory", scmProjectedResource({ kind: "dir" }, { groupId: "changes", contextValue: "subversionr.changedDirectory" })],
    ["deleted", scmProjectedResource({ localStatus: "deleted", nodeStatus: "deleted", textStatus: "deleted" })],
  ])("does not provide lenses for %s resources", (_label, resource) => {
    const provider = fileHeaderProvider({
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [resource],
          }),
        ],
      ]),
    });

    expect(provider.provideCodeLenses(textDocument("C:\\workspace\\src\\main.c"))).toEqual([]);
  });
});

function fileHeaderProvider(options: {
  settings?: LensSettings;
  sessions?: RepositorySession[];
  projections?: Map<string, ScmRepositoryProjection | undefined>;
  sourceControlProjection?: Pick<SourceControlProjectionService, "getProjectedResource">;
  workspaceTrusted?: boolean;
} = {}): FileHeaderCodeLensProvider<TestCodeLens> {
  const projections = options.projections ?? new Map([["repo-uuid:C:/workspace", scmProjection()]]);
  return new FileHeaderCodeLensProvider<TestCodeLens>({
    settings: () => options.settings ?? lensSettings(),
    sessionService: fakeSessionService(options.sessions ?? [repositorySession()]),
    sourceControlProjection: options.sourceControlProjection ?? fakeSourceControlProjection(projections),
    workspaceTrusted: () => options.workspaceTrusted ?? true,
    api: {
      createEventEmitter: () => fakeEventEmitter(),
      createRange: (startLine, startCharacter, endLine, endCharacter) => ({
        startLine,
        startCharacter,
        endLine,
        endCharacter,
      }),
      createCodeLens: (range) => ({ range }),
      localize: (message, ...args) =>
        args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message),
    },
  });
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

function textDocument(fsPath: string, lineCount = 1, scheme = "file") {
  return {
    uri: {
      scheme,
      fsPath,
    },
    lineCount,
  };
}

interface TestCodeLens {
  range: unknown;
  command?: {
    command: string;
    title: string;
    arguments?: unknown[];
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

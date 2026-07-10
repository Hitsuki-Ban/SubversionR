import { describe, expect, it, vi } from "vitest";
import { ActiveEditorContextService } from "../src/editor/activeEditorContextService";
import type { LensSettings } from "../src/lens/lensSettings";
import type { RepositorySession, RepositorySessionService } from "../src/repository/repositorySessionService";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type {
  ScmProjectedResource,
  ScmProjectedResourceLookup,
  ScmRepositoryProjection,
} from "../src/scm/sourceControlResourceStore";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";

describe("ActiveEditorContextService", () => {
  it("sets history, base-diffable, and previous-diffable context keys for a projected active file", async () => {
    const api = fakeApi(textDocument("C:\\workspace\\SRC\\MAIN.C"));
    const service = activeEditorContextService({ api });

    await service.refresh();

    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorHistoryFile", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorBaseDiffable", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorPreviousDiffable", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorLineHistoryFile", false);
  });

  it("sets file inspection context keys for a projected changelisted active file", async () => {
    const api = fakeApi(textDocument("C:\\workspace\\SRC\\REVIEW.C"));
    const service = activeEditorContextService({
      api,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource(
                { path: "src/review.c", changelist: "review" },
                {
                  groupId: "changelist:review",
                },
              ),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorHistoryFile", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorBaseDiffable", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorPreviousDiffable", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorLineHistoryFile", false);
  });

  it("sets only history context for projected files that are not base-diffable", async () => {
    const api = fakeApi(textDocument("C:\\workspace\\src\\main.c"));
    const service = activeEditorContextService({
      api,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "normal",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorHistoryFile", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorBaseDiffable", false);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorPreviousDiffable", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorLineHistoryFile", true);
  });

  it("sets line history context for a projected changelisted active file that is safe to blame", async () => {
    const api = fakeApi(textDocument("C:\\workspace\\SRC\\REVIEW.C"));
    const service = activeEditorContextService({
      api,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource(
                {
                  path: "src/review.c",
                  changelist: "review",
                  localStatus: "normal",
                  textStatus: "normal",
                  propertyStatus: "normal",
                },
                {
                  groupId: "changelist:review",
                },
              ),
            ],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorHistoryFile", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorLineHistoryFile", true);
  });

  it("clears only previous-diffable context when a projected file has no previous revision candidate", async () => {
    const api = fakeApi(textDocument("C:\\workspace\\src\\main.c"));
    const service = activeEditorContextService({
      api,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [scmProjectedResource({ changedRevision: 0 })],
          }),
        ],
      ]),
    });

    await service.refresh();

    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorHistoryFile", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorBaseDiffable", true);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorPreviousDiffable", false);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorLineHistoryFile", false);
  });

  it("clears context keys when the active file is outside open repositories before projection lookup", async () => {
    const api = fakeApi(textDocument("D:\\outside\\src\\main.c"));
    const getProjectedResource = vi.fn<SourceControlProjectionService["getProjectedResource"]>();
    const service = activeEditorContextService({
      api,
      sourceControlProjection: { getProjectedResource },
    });

    await service.refresh();

    expect(getProjectedResource).not.toHaveBeenCalled();
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorHistoryFile", false);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorBaseDiffable", false);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorPreviousDiffable", false);
    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorLineHistoryFile", false);
  });

  it.each([
    ["disabled settings", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ textStatus: "normal" }), lensSettings({ enabled: false })],
    ["dirty document", textDocument("C:\\workspace\\src\\main.c", { isDirty: true }), scmProjectedResource({ textStatus: "normal" }), undefined],
    ["oversized document", textDocument("C:\\workspace\\src\\main.c", { lineCount: 20001 }), scmProjectedResource({ textStatus: "normal" }), undefined],
    ["text-modified resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ textStatus: "modified" }), undefined],
    ["added resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "added", nodeStatus: "normal", textStatus: "normal" }), undefined],
    ["conflicted resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "conflicted", nodeStatus: "normal", textStatus: "normal" }), undefined],
    ["unversioned resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "unversioned", nodeStatus: "normal", textStatus: "normal" }), undefined],
    ["deleted resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "deleted", nodeStatus: "deleted", textStatus: "normal" }), undefined],
    ["missing resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "missing", nodeStatus: "missing", textStatus: "normal" }), undefined],
    ["replaced resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "replaced", nodeStatus: "normal", textStatus: "normal" }), undefined],
    ["obstructed resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "obstructed", nodeStatus: "normal", textStatus: "normal" }), undefined],
    ["incomplete resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "incomplete", nodeStatus: "normal", textStatus: "normal" }), undefined],
    ["deleted node status", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ nodeStatus: "deleted", textStatus: "normal" }), undefined],
    ["missing text status", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ nodeStatus: "normal", textStatus: "missing" }), undefined],
    ["external resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ external: true, textStatus: "normal" }), undefined],
    ["remote resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ textStatus: "normal" }, { source: "remote" }), undefined],
    ["conflicts group resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ textStatus: "normal" }, { groupId: "conflicts" }), undefined],
    ["base-diffable context resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ textStatus: "normal" }, { contextValue: "subversionr.changedFile.baseDiffable" }), undefined],
    ["directory resource", textDocument("C:\\workspace\\src\\main.c"), scmProjectedResource({ kind: "dir", textStatus: "normal" }), undefined],
  ])("keeps line history context false for %s", async (_label, document, resource, settings) => {
    const api = fakeApi(document);
    const service = activeEditorContextService({
      api,
      settings,
      projections: new Map([["repo-uuid:C:/workspace", scmProjection({ resources: [resource] })]]),
    });

    await service.refresh();

    expect(api.setContext).toHaveBeenCalledWith("subversionr.activeEditorLineHistoryFile", false);
  });
});

function activeEditorContextService(options: {
  api?: FakeApi;
  settings?: LensSettings;
  sessions?: RepositorySession[];
  projections?: Map<string, ScmRepositoryProjection | undefined>;
  sourceControlProjection?: Pick<SourceControlProjectionService, "getProjectedResource">;
} = {}): ActiveEditorContextService {
  const projections = options.projections ?? new Map([["repo-uuid:C:/workspace", scmProjection()]]);
  return new ActiveEditorContextService({
    settings: () => options.settings ?? lensSettings(),
    sessionService: fakeSessionService(options.sessions ?? [repositorySession()]),
    sourceControlProjection: options.sourceControlProjection ?? fakeSourceControlProjection(projections),
    api: options.api ?? fakeApi(textDocument("C:\\workspace\\src\\main.c")),
  });
}

function fakeApi(document: ActiveEditorTextDocument | undefined): FakeApi {
  return {
    activeTextDocument: vi.fn(() => document),
    setContext: vi.fn(async () => undefined),
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
): ActiveEditorTextDocument {
  return {
    uri: {
      scheme: options.scheme ?? "file",
      fsPath,
    },
    lineCount: options.lineCount ?? 20,
    isDirty: options.isDirty ?? false,
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

interface ActiveEditorTextDocument {
  uri: {
    scheme: string;
    fsPath: string;
  };
  lineCount: number;
  isDirty: boolean;
}

interface FakeApi {
  activeTextDocument: ReturnType<typeof vi.fn<() => ActiveEditorTextDocument | undefined>>;
  setContext: ReturnType<typeof vi.fn<(key: string, value: boolean) => Promise<void>>>;
}

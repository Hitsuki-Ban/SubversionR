import { describe, expect, it, vi } from "vitest";
import {
  DIAGNOSTICS_DOCUMENT_URI_SCHEME,
  DiagnosticsReadonlyDocumentProvider,
  type DiagnosticsDocumentUriComponents,
  type RepositoryReadonlyReportDocument,
} from "../src/diagnostics/diagnosticsDocumentProvider";

function createProvider(currentEpochs: Readonly<Record<string, number>> = { "repo-1": 7 }) {
  const fire = vi.fn();
  const provider = new DiagnosticsReadonlyDocumentProvider<DiagnosticsDocumentUriComponents>({
    createEventEmitter: () => ({
      event: vi.fn(() => ({ dispose: vi.fn() })),
      fire,
      dispose: vi.fn(),
    }),
    uriFromComponents: (components) => components,
    currentRepositoryEpoch: (repositoryId) => currentEpochs[repositoryId],
  });
  return { provider, fire };
}

const repositoryPropertiesReport: RepositoryReadonlyReportDocument = {
  kind: "repository-properties",
  repositoryId: "repo-1",
  epoch: 7,
  path: ".",
  content: "# Properties\n\nfirst\n",
};

describe("DiagnosticsReadonlyDocumentProvider", () => {
  it("stores version report JSON behind a readonly diagnostics URI", () => {
    const { provider } = createProvider();

    const uri = provider.createDocument('{"kind":"subversionr.versionReport"}\n');

    expect(uri).toMatchObject({
      scheme: DIAGNOSTICS_DOCUMENT_URI_SCHEME,
      authority: "readonly",
      path: "/version-report.json",
      query: "id=1",
    });
    expect(provider.provideTextDocumentContent(uri)).toBe('{"kind":"subversionr.versionReport"}\n');
  });

  it("reuses a deterministic report URI, updates its content, and emits a change", () => {
    const { provider, fire } = createProvider();
    const firstUri = provider.createOrUpdateRepositoryReport(repositoryPropertiesReport);

    const secondUri = provider.createOrUpdateRepositoryReport({
      ...repositoryPropertiesReport,
      content: "# Properties\n\nsecond\n",
    });

    expect(secondUri).toBe(firstUri);
    expect(secondUri).toMatchObject({
      scheme: DIAGNOSTICS_DOCUMENT_URI_SCHEME,
      authority: "readonly",
      path: "/repository-properties.md",
      query: "repositoryId=repo-1&epoch=7&path=.",
    });
    expect(fire).toHaveBeenCalledOnce();
    expect(fire).toHaveBeenCalledWith(firstUri);
    expect(provider.provideTextDocumentContent(firstUri)).toBe("# Properties\n\nsecond\n");
  });

  it("uses distinct URIs for report kind, repository path, and epoch", () => {
    const { provider } = createProvider({ "repo-1": 8 });
    const base = provider.createOrUpdateRepositoryReport(repositoryPropertiesReport);
    const kind = provider.createOrUpdateRepositoryReport({
      ...repositoryPropertiesReport,
      kind: "repository-mergeinfo",
    });
    const path = provider.createOrUpdateRepositoryReport({
      ...repositoryPropertiesReport,
      kind: "resource-properties",
      path: "src/main.ts",
    });
    const epoch = provider.createOrUpdateRepositoryReport({
      ...repositoryPropertiesReport,
      epoch: 8,
    });

    expect(new Set([base.path + base.query, kind.path + kind.query, path.path + path.query, epoch.path + epoch.query])).toHaveProperty(
      "size",
      4,
    );
  });

  it("releases version and repository report content without consulting session state", () => {
    const epochs: Record<string, number> = { "repo-1": 7 };
    const { provider } = createProvider(epochs);
    const versionUri = provider.createDocument("{}\n");
    const reportUri = provider.createOrUpdateRepositoryReport(repositoryPropertiesReport);

    provider.releaseDocument(versionUri);
    delete epochs["repo-1"];
    provider.releaseDocument(reportUri);

    expect(() => provider.provideTextDocumentContent(versionUri)).toThrow(
      expect.objectContaining({ code: "SUBVERSIONR_DIAGNOSTICS_DOCUMENT_NOT_FOUND" }),
    );
    epochs["repo-1"] = 7;
    expect(() => provider.provideTextDocumentContent(reportUri)).toThrow(
      expect.objectContaining({ code: "SUBVERSIONR_DIAGNOSTICS_DOCUMENT_NOT_FOUND" }),
    );
  });

  it.each([
    ["missing query key", "repositoryId=repo-1&epoch=7"],
    ["duplicate query key", "repositoryId=repo-1&epoch=7&path=.&path=src"],
    ["unknown query key", "repositoryId=repo-1&epoch=7&path=.&extra=true"],
    ["invalid epoch", "repositoryId=repo-1&epoch=-1&path=."],
    ["noncanonical path", "repositoryId=repo-1&epoch=7&path=..%2Fsecret"],
    ["noncanonical order", "epoch=7&repositoryId=repo-1&path=."],
    ["invalid percent encoding", "repositoryId=repo-1&epoch=7&path=%"],
  ])("rejects a repository report URI with %s", (_name, query) => {
    const { provider } = createProvider();
    const uri = provider.createOrUpdateRepositoryReport(repositoryPropertiesReport);

    expect(() => provider.provideTextDocumentContent({ ...uri, query })).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_DIAGNOSTICS_DOCUMENT_URI_INVALID",
        category: "input",
        messageKey: "error.diagnostics.documentUriInvalid",
        safeArgs: expect.any(Object),
        retryable: false,
        diagnostics: null,
      }),
    );
  });

  it("rejects non-exact version report queries", () => {
    const { provider } = createProvider();
    const uri = provider.createDocument("{}\n");

    expect(() => provider.provideTextDocumentContent({ ...uri, query: "id=1&extra=true" })).toThrow(
      expect.objectContaining({ code: "SUBVERSIONR_DIAGNOSTICS_DOCUMENT_URI_INVALID" }),
    );
  });

  it("rejects invalid repository report input before creating a URI", () => {
    const { provider } = createProvider();

    expect(() =>
      provider.createOrUpdateRepositoryReport({ ...repositoryPropertiesReport, path: "src/../secret" }),
    ).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_DIAGNOSTICS_REPORT_DOCUMENT_INVALID",
        safeArgs: { field: "path" },
      }),
    );
  });

  it("requires repository report targets to use the root while allowing root resource reports", () => {
    const { provider } = createProvider();
    const repositoryUri = provider.createOrUpdateRepositoryReport(repositoryPropertiesReport);

    expect(() =>
      provider.createOrUpdateRepositoryReport({
        ...repositoryPropertiesReport,
        path: "src/main.ts",
      }),
    ).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_DIAGNOSTICS_REPORT_DOCUMENT_INVALID",
        safeArgs: { field: "path" },
      }),
    );
    const resourceRootUri = provider.createOrUpdateRepositoryReport({
      ...repositoryPropertiesReport,
      kind: "resource-properties",
      path: ".",
    });
    expect(resourceRootUri.path).toBe("/resource-properties.md");
    expect(resourceRootUri.query).toBe("repositoryId=repo-1&epoch=7&path=.");
    expect(resourceRootUri).not.toEqual(repositoryUri);
    expect(provider.provideTextDocumentContent(resourceRootUri)).toBe(repositoryPropertiesReport.content);
  });

  it("reports a closed repository session separately from missing content", () => {
    const { provider } = createProvider({});
    const uri = provider.createOrUpdateRepositoryReport(repositoryPropertiesReport);

    expect(() => provider.provideTextDocumentContent(uri)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_DIAGNOSTICS_REPORT_REPOSITORY_NOT_OPEN",
        category: "lifecycle",
        messageKey: "error.diagnostics.reportRepositoryNotOpen",
        safeArgs: { repositoryId: "repo-1", epoch: 7 },
      }),
    );
  });

  it("reports a stale repository session with expected and actual epochs", () => {
    const { provider } = createProvider({ "repo-1": 8 });
    const uri = provider.createOrUpdateRepositoryReport(repositoryPropertiesReport);

    expect(() => provider.provideTextDocumentContent(uri)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_DIAGNOSTICS_REPORT_SESSION_STALE",
        category: "lifecycle",
        messageKey: "error.diagnostics.reportSessionStale",
        safeArgs: { repositoryId: "repo-1", expectedEpoch: 7, actualEpoch: 8 },
      }),
    );
  });
});

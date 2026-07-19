import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousRedactionReport,
  type InstalledSvnAnonymousRedactionReportOptions,
} from "../src/diagnostics/installedSvnAnonymousRedactionReport";
import { OperationDiagnostics } from "../src/diagnostics/operationDiagnostics";

const TOKEN = "installed-i6-redaction-token";
const REPOSITORY_URL = "svn://127.0.0.1:3691/repo/trunk";
const TARGET_PATH = "C:/evidence/i6-redaction-checkout";
const OPERATION_ID = "70000000-0000-4000-8000-000000000001";
const SECRET_TOKEN = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const URL_MARKER = `[REDACTED:url:${fnv1a(REPOSITORY_URL)}]`;
const PATH_MARKER = `[REDACTED:path:${fnv1a(TARGET_PATH)}]`;
const SECRET_MARKER = "[REDACTED:secret]";

describe("installed SVN anonymous redaction report", () => {
  it("checks out once through the real typed client and returns only bounded redaction evidence", async () => {
    const sendRequest = vi.fn().mockResolvedValue({ workingCopyPath: TARGET_PATH, revision: 2 });
    const collectDiagnosticsComposite = vi.fn().mockResolvedValue(diagnosticsComposite());
    const report = await collectInstalledSvnAnonymousRedactionReport({
      ...baseOptions(),
      initialize: vi.fn().mockResolvedValue(connection({ sendRequest })),
      collectDiagnosticsComposite,
    });

    expect(sendRequest).toHaveBeenCalledOnce();
    expect(sendRequest).toHaveBeenCalledWith("repository/checkout", {
      url: REPOSITORY_URL,
      targetPath: TARGET_PATH,
      revision: "head",
      depth: "infinity",
      ignoreExternals: true,
      remote: expectedRemoteEnvelope(),
    });
    expect(collectDiagnosticsComposite).toHaveBeenCalledOnce();
    expect(collectDiagnosticsComposite).toHaveBeenCalledWith({
      repositoryUrl: REPOSITORY_URL,
      targetPath: TARGET_PATH,
      secretToken: SECRET_TOKEN,
    });
    expect(report).toEqual({
      schema: "subversionr.release.m8-i6-installed-vsix-redaction.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousRedactionReport",
      status: "passed",
      cell: "redaction",
      surface: "installed-vsix-extension-host",
      checkoutRevision: 2,
      targetPathSha256: createHash("sha256").update(TARGET_PATH, "utf8").digest("hex"),
      inputContainedRawUrl: true,
      inputContainedRawPath: true,
      inputContainedRawToken: true,
      rawUrlCount: 0,
      rawPathCount: 0,
      secretTokenCount: 0,
      urlMarkerCount: 3,
      pathMarkerCount: 3,
      secretMarkerCount: 3,
      diagnosticValueCount: 3,
      maxDiagnosticBytes: expect.any(Number),
      boundedDiagnostics: true,
      protocol: { major: 1, minor: 35 },
      trust: { remoteSubmissionEnabled: true, epoch: 7 },
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      redaction: { paths: "redacted", urls: "redacted", secrets: "redacted" },
      diagnosticsRedacted: true,
    });
    expect(report.maxDiagnosticBytes).toEqual(expect.any(Number));
    expect(report.maxDiagnosticBytes as number).toBeLessThanOrEqual(32_768);
    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain(REPOSITORY_URL);
    expect(serialized).not.toContain(TARGET_PATH);
    expect(serialized).not.toContain(SECRET_TOKEN);
    expect(serialized).not.toContain(OPERATION_ID);
    expect(serialized).not.toContain(TOKEN);
  });

  it("rejects missing or mismatched evidence tokens before initialization", async () => {
    const missing = baseOptions();
    missing.expectedToken = undefined;
    await expect(collectInstalledSvnAnonymousRedactionReport(missing)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_FORBIDDEN",
    });
    expect(missing.initialize).not.toHaveBeenCalled();

    const mismatch = baseOptions();
    mismatch.request = { ...request(), token: "wrong-token" };
    await expect(collectInstalledSvnAnonymousRedactionReport(mismatch)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_FORBIDDEN",
    });
    expect(mismatch.initialize).not.toHaveBeenCalled();
  });

  it.each([
    ["an extra key", { ...request(), extra: true }],
    ["a relative target", { ...request(), targetPath: "relative/checkout" }],
    ["a non-canonical operation ID", { ...request(), operationId: "NOT-A-UUID" }],
    ["the nil operation ID", { ...request(), operationId: "00000000-0000-0000-0000-000000000000" }],
    ["a different timeout", { ...request(), timeoutMs: 299_999 }],
    ["a zero expected revision", { ...request(), expectedRevision: 0 }],
    ["a non-integer expected revision", { ...request(), expectedRevision: 2.5 }],
    ["a short secret token", { ...request(), secretToken: "abcd" }],
    ["an uppercase secret token", { ...request(), secretToken: SECRET_TOKEN.toUpperCase() }],
    ["the harness token as secret", { ...request(), secretToken: TOKEN }],
    ["the operation ID as secret", { ...request(), secretToken: OPERATION_ID }],
  ])("rejects %s before initialization", async (_label, invalidRequest) => {
    const options = baseOptions();
    options.request = invalidRequest;
    await expect(collectInstalledSvnAnonymousRedactionReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_REQUEST_INVALID",
    });
    expect(options.initialize).not.toHaveBeenCalled();
  });

  it.each([
    "svn://localhost:3691/repo/trunk",
    "svn://127.0.0.1/repo/trunk",
    "svn://127.0.0.1:3691/repo",
    "svn://user@127.0.0.1:3691/repo/trunk",
    "svn://127.0.0.1:3691/repo/trunk?query=1",
    "svn://127.0.0.1:65536/repo/trunk",
  ])("rejects the non-exact direct origin %s", async (repositoryUrl) => {
    const options = baseOptions();
    options.request = { ...request(), repositoryUrl };
    await expect(collectInstalledSvnAnonymousRedactionReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_ORIGIN_INVALID",
    });
    expect(options.initialize).not.toHaveBeenCalled();
  });

  it.each([
    ["a failed checkout", vi.fn().mockRejectedValue(new Error("failed"))],
    ["a different target", vi.fn().mockResolvedValue({ workingCopyPath: "C:/evidence/other", revision: 2 })],
    ["an invalid revision", vi.fn().mockResolvedValue({ workingCopyPath: TARGET_PATH, revision: -1 })],
    ["a different valid revision", vi.fn().mockResolvedValue({ workingCopyPath: TARGET_PATH, revision: 3 })],
  ])("rejects %s", async (_label, sendRequest) => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection({ sendRequest }));
    await expect(collectInstalledSvnAnonymousRedactionReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_CHECKOUT_INVALID",
    });
    expect(sendRequest).toHaveBeenCalledOnce();
  });

  it("fails closed when the proven diagnostic input no longer contains every raw value", async () => {
    const options = baseOptions();
    options.operationDiagnostics = {
      recordRpcFailure: (_method, error) => {
        const safeArgs = (error as { safeArgs: Record<string, unknown> }).safeArgs;
        delete safeArgs.repositoryUrl;
      },
      snapshot: () => [markerLine()],
    };
    await expect(collectInstalledSvnAnonymousRedactionReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_INPUT_INVALID",
    });
  });

  it("accepts the native bridge's canonical Windows separator normalization for the same target", async () => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection({
      sendRequest: vi.fn().mockResolvedValue({
        workingCopyPath: TARGET_PATH.replaceAll("/", "\\"),
        revision: 2,
      }),
    }));

    await expect(collectInstalledSvnAnonymousRedactionReport(options)).resolves.toMatchObject({
      status: "passed",
      checkoutRevision: 2,
    });
  });

  it.each([
    ["raw URL", { leaked: REPOSITORY_URL }],
    ["raw path", { leaked: TARGET_PATH }],
    ["secret token", { leaked: SECRET_TOKEN }],
  ])("rejects a diagnostics bundle that leaks the %s", async (_label, leak) => {
    const options = baseOptions();
    options.collectDiagnosticsComposite = vi.fn().mockResolvedValue({
      ...diagnosticsComposite(),
      diagnosticsBundle: { ...diagnosticsBundle(), ...leak },
    });
    await expect(collectInstalledSvnAnonymousRedactionReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_LEAK",
    });
  });

  it("rejects an operation diagnostics path missing any required production marker", async () => {
    const options = baseOptions();
    options.operationDiagnostics = {
      recordRpcFailure: vi.fn(),
      snapshot: () => [JSON.stringify({ url: URL_MARKER, path: PATH_MARKER })],
    };
    await expect(collectInstalledSvnAnonymousRedactionReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_MARKERS_INVALID",
    });
  });

  it("rejects synthetic URL and path markers not derived from the raw inputs", async () => {
    const options = baseOptions();
    options.operationDiagnostics = {
      recordRpcFailure: vi.fn(),
      snapshot: () => [JSON.stringify({
        url: "[REDACTED:url:00000000]",
        path: "[REDACTED:path:00000000]",
        secret: SECRET_MARKER,
      })],
    };
    await expect(collectInstalledSvnAnonymousRedactionReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_MARKERS_INVALID",
    });
  });

  it("rejects any serialized diagnostic value above 32 KiB", async () => {
    const options = baseOptions();
    options.collectDiagnosticsComposite = vi.fn().mockResolvedValue({
      ...diagnosticsComposite(),
      diagnosticsBundle: {
        ...diagnosticsBundle(),
        padding: "x".repeat(32_769),
      },
    });
    await expect(collectInstalledSvnAnonymousRedactionReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_BOUNDS_INVALID",
    });
  });

  it("rejects a diagnostics composite with missing or extra fields", async () => {
    const missing = baseOptions();
    missing.collectDiagnosticsComposite = vi.fn().mockResolvedValue({
      diagnosticsBundle: diagnosticsBundle(),
    });
    await expect(collectInstalledSvnAnonymousRedactionReport(missing)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID",
    });

    const extra = baseOptions();
    extra.collectDiagnosticsComposite = vi.fn().mockResolvedValue({
      ...diagnosticsComposite(),
      fallback: true,
    });
    await expect(collectInstalledSvnAnonymousRedactionReport(extra)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID",
    });
  });

  it("rejects a fake composite canary with a missing marker, raw leak, or oversized value", async () => {
    const cases: Array<[unknown, string]> = [
      [{ url: URL_MARKER, path: PATH_MARKER }, "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_MARKERS_INVALID"],
      [{ url: REPOSITORY_URL, path: PATH_MARKER, secret: SECRET_MARKER }, "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_MARKERS_INVALID"],
      [{
        url: URL_MARKER,
        path: PATH_MARKER,
        secret: SECRET_MARKER,
        padding: "x".repeat(32_769),
      }, "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_BOUNDS_INVALID"],
    ];
    for (const [redactedCanary, code] of cases) {
      const options = baseOptions();
      options.collectDiagnosticsComposite = vi.fn().mockResolvedValue({
        diagnosticsBundle: diagnosticsBundle(),
        redactedCanary,
      });
      await expect(collectInstalledSvnAnonymousRedactionReport(options)).rejects.toMatchObject({ code });
    }

    const leaked = baseOptions();
    leaked.collectDiagnosticsComposite = vi.fn().mockResolvedValue({
      diagnosticsBundle: diagnosticsBundle(),
      redactedCanary: {
        url: URL_MARKER,
        path: PATH_MARKER,
        secret: SECRET_MARKER,
        leaked: SECRET_TOKEN,
      },
    });
    await expect(collectInstalledSvnAnonymousRedactionReport(leaked)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_LEAK",
    });
  });

  it("rejects trust drift after checkout or diagnostics collection", async () => {
    const afterCheckout = baseOptions();
    afterCheckout.initialize = vi.fn().mockResolvedValue(connection({ currentTrustEpochs: [7, 7, 8] }));
    await expect(collectInstalledSvnAnonymousRedactionReport(afterCheckout)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_TRUST_EPOCH_INVALID",
    });

    const afterDiagnostics = baseOptions();
    afterDiagnostics.initialize = vi.fn().mockResolvedValue(connection({ currentTrustEpochs: [7, 7, 7, 8] }));
    await expect(collectInstalledSvnAnonymousRedactionReport(afterDiagnostics)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_TRUST_EPOCH_INVALID",
    });
  });

  it("rejects malformed counters and any authentication activity across the whole proof", async () => {
    const malformed = baseOptions();
    malformed.authActivity = () => ({
      credentialRequests: -1,
      credentialSettlements: 0,
      certificateRequests: 0,
    });
    await expect(collectInstalledSvnAnonymousRedactionReport(malformed)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_AUTH_ACTIVITY_INVALID",
    });
    expect(malformed.initialize).not.toHaveBeenCalled();

    let reads = 0;
    const changed = baseOptions();
    changed.authActivity = () => ({
      credentialRequests: reads++ === 0 ? 0 : 1,
      credentialSettlements: 0,
      certificateRequests: 0,
    });
    await expect(collectInstalledSvnAnonymousRedactionReport(changed)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_AUTH_ACTIVITY_INVALID",
    });
  });
});

function baseOptions(): InstalledSvnAnonymousRedactionReportOptions {
  return {
    expectedToken: TOKEN,
    request: request(),
    initialize: vi.fn().mockResolvedValue(connection()),
    authActivity: () => ({ credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 }),
    operationDiagnostics: operationDiagnostics(),
    collectDiagnosticsComposite: vi.fn().mockResolvedValue(diagnosticsComposite()),
  };
}

function request(): Record<string, unknown> {
  return {
    token: TOKEN,
    repositoryUrl: REPOSITORY_URL,
    targetPath: TARGET_PATH,
    operationId: OPERATION_ID,
    timeoutMs: 300_000,
    secretToken: SECRET_TOKEN,
    expectedRevision: 2,
  };
}

function diagnosticsBundle(): Record<string, unknown> {
  return {
    kind: "subversionr.diagnosticsBundle",
    redaction: {
      mode: "default",
      paths: "redacted",
      urls: "redacted",
      secrets: "redacted",
      repositoryLogs: "omitted",
      sourceContent: "omitted",
    },
  };
}

function diagnosticsComposite(): Record<string, unknown> {
  return {
    diagnosticsBundle: diagnosticsBundle(),
    redactedCanary: { url: URL_MARKER, path: PATH_MARKER, secret: SECRET_MARKER },
  };
}

function operationDiagnostics(): OperationDiagnostics {
  return new OperationDiagnostics({ clear: vi.fn(), error: vi.fn(), show: vi.fn() });
}

function markerLine(): string {
  return JSON.stringify({ url: URL_MARKER, path: PATH_MARKER, secret: SECRET_MARKER });
}

interface ConnectionOverrides {
  currentTrustEpochs?: number[];
  sendRequest?: ReturnType<typeof vi.fn>;
}

function connection(overrides: ConnectionOverrides = {}): Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
> {
  const currentTrustEpochs = overrides.currentTrustEpochs ?? [7];
  let trustRead = 0;
  return {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      acknowledgedTrustEpoch: 7,
      capabilities: {
        realLibsvnBridge: true,
        repositoryCheckout: true,
        diagnosticsGet: true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        remoteSvnAnonymous: true,
      },
    } as BackendConnection["initializeResult"],
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => {
      const value = currentTrustEpochs[Math.min(trustRead, currentTrustEpochs.length - 1)];
      trustRead += 1;
      return value!;
    },
    sendRequest: (overrides.sendRequest ?? vi.fn().mockResolvedValue({
      workingCopyPath: TARGET_PATH,
      revision: 2,
    })) as BackendConnection["sendRequest"],
  };
}

function expectedRemoteEnvelope(): Record<string, unknown> {
  const authority = { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3691 };
  return {
    version: 1,
    operationId: OPERATION_ID,
    intent: "foreground",
    interaction: "forbidden",
    timeoutMs: 300_000,
    workspaceTrust: "trusted",
    trustEpoch: 7,
    profile: {
      schema: "subversionr.remote-profile.v1",
      profileId: "installed-i6-svn-anonymous-redaction",
      authority,
      serverAuth: "anonymous",
      serverAccount: "none",
      serverCredentialPersistence: "secretStorage",
      proxy: "none",
      ssh: "none",
      redirectPolicy: "rejectAll",
    },
    expectedOrigin: authority,
  };
}

function fnv1a(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

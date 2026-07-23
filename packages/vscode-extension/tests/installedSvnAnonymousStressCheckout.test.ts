import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousStressCheckout,
  createInstalledSvnAnonymousStressSessionSha256,
  type InstalledSvnAnonymousStressCheckoutOptions,
} from "../src/diagnostics/installedSvnAnonymousStressCheckout";

const TOKEN = "installed-i6-stress-token";
const REPOSITORY_URL = "svn://127.0.0.1:3691/repo/trunk";
const CHECKOUT_PATH = "C:/evidence/i6-stress-checkout";
const OPERATION_ID = "10000000-0000-4000-8000-000000000001";
const EXTENSION_HOST_SESSION_SHA256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

describe("installed SVN anonymous stress checkout", () => {
  it("executes one real typed checkout with the supplied operation ID and returns bounded redacted evidence", async () => {
    const sendRequest = vi.fn().mockResolvedValue({ workingCopyPath: CHECKOUT_PATH, revision: 2 });
    const activeConnection = connection({ sendRequest });
    const report = await collectInstalledSvnAnonymousStressCheckout({
      ...baseOptions(),
      initialize: vi.fn().mockResolvedValue(activeConnection),
    });

    expect(report).toEqual({
      schema: "subversionr.release.m8-i6-installed-svn-anonymous-stress-checkout.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousStressCheckout",
      operationId: OPERATION_ID,
      extensionHostSessionSha256: EXTENSION_HOST_SESSION_SHA256,
      revision: 2,
      protocol: { major: 1, minor: 35 },
      trust: { acknowledgedEpoch: 7, consistent: true },
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    });
    expect(sendRequest).toHaveBeenCalledOnce();
    expect(sendRequest).toHaveBeenCalledWith("repository/checkout", {
      url: REPOSITORY_URL,
      targetPath: CHECKOUT_PATH,
      revision: 2,
      depth: "infinity",
      ignoreExternals: true,
      remote: {
        version: 1,
        operationId: OPERATION_ID,
        intent: "foreground",
        interaction: "forbidden",
        timeoutMs: 300_000,
        workspaceTrust: "trusted",
        trustEpoch: 7,
        profile: {
          schema: "subversionr.remote-profile.v1",
          profileId: "installed-i6-svn-anonymous-stress",
          authority: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3691 },
          serverAuth: "anonymous",
          serverAccount: "none",
          serverCredentialPersistence: "secretStorage",
          proxy: "none",
          ssh: "none",
          redirectPolicy: "rejectAll",
        },
        expectedOrigin: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3691 },
      },
    });
    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain(REPOSITORY_URL);
    expect(serialized).not.toContain(CHECKOUT_PATH);
  });

  it("fails closed for a missing or mismatched independent token", async () => {
    const missing = baseOptions();
    missing.expectedToken = undefined;
    await expect(collectInstalledSvnAnonymousStressCheckout(missing)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_FORBIDDEN",
    });
    expect(missing.initialize).not.toHaveBeenCalled();

    const mismatch = baseOptions();
    mismatch.request = { ...request(), token: "wrong-token" };
    await expect(collectInstalledSvnAnonymousStressCheckout(mismatch)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_FORBIDDEN",
    });
    expect(mismatch.initialize).not.toHaveBeenCalled();
  });

  it("binds the bounded session hash to the one-time token and Extension Host process", () => {
    const first = createInstalledSvnAnonymousStressSessionSha256("token-one");
    const repeated = createInstalledSvnAnonymousStressSessionSha256("token-one");
    const second = createInstalledSvnAnonymousStressSessionSha256("token-two");
    expect(first).toMatch(/^[0-9a-f]{64}$/);
    expect(repeated).toBe(first);
    expect(second).toMatch(/^[0-9a-f]{64}$/);
    expect(second).not.toBe(first);
    expect(() => createInstalledSvnAnonymousStressSessionSha256("")).toThrowError(
      expect.objectContaining({ code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_SESSION_INVALID" }),
    );
  });

  it("rejects an invalid Extension Host session hash before backend initialization", async () => {
    const options = baseOptions();
    options.extensionHostSessionSha256 = "not-a-hash";
    await expect(collectInstalledSvnAnonymousStressCheckout(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_SESSION_INVALID",
    });
    expect(options.initialize).not.toHaveBeenCalled();
  });

  it.each([
    ["an extra request key", { ...request(), extra: true }],
    ["a relative checkout target", { ...request(), checkoutPath: "relative/checkout" }],
    ["a negative revision", { ...request(), checkoutRevision: -1 }],
    ["an oversized revision", { ...request(), checkoutRevision: 2_147_483_648 }],
    ["a non-canonical operation ID", { ...request(), operationId: "ABCDEF00-0000-4000-8000-000000000001" }],
    ["the nil operation ID", { ...request(), operationId: "00000000-0000-0000-0000-000000000000" }],
  ])("rejects %s before backend initialization", async (_description, invalidRequest) => {
    const options = baseOptions();
    options.request = invalidRequest;
    await expect(collectInstalledSvnAnonymousStressCheckout(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_REQUEST_INVALID",
    });
    expect(options.initialize).not.toHaveBeenCalled();
  });

  it.each([
    "https://127.0.0.1:3691/repo/trunk",
    "svn://svn.example.invalid:3691/repo/trunk",
    "svn://user@127.0.0.1:3691/repo/trunk",
    "svn://127.0.0.1:3691/",
    "svn://127.0.0.1:3691/repo/trunk?query=1",
  ])("rejects the uncontrolled origin %s before backend initialization", async (repositoryUrl) => {
    const options = baseOptions();
    options.request = { ...request(), repositoryUrl };
    await expect(collectInstalledSvnAnonymousStressCheckout(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_ORIGIN_INVALID",
    });
    expect(options.initialize).not.toHaveBeenCalled();
  });

  it.each([
    ["protocol major", { protocolMajor: 2 }],
    ["protocol minor", { protocolMinor: 34 }],
    ["real bridge", { capabilities: { realLibsvnBridge: false } }],
    ["checkout", { capabilities: { repositoryCheckout: false } }],
    ["remote envelope", { capabilities: { remoteOperationEnvelope: false } }],
    ["worker isolation", { capabilities: { remoteWorkerIsolation: false } }],
    ["svn anonymous", { capabilities: { remoteSvnAnonymous: false } }],
    ["remote submission", { remoteSubmissionEnabled: false }],
  ])("rejects a candidate without the required %s capability", async (_description, override) => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(override));
    await expect(collectInstalledSvnAnonymousStressCheckout(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_CAPABILITY_UNAVAILABLE",
    });
  });

  it("rejects an invalid, stale, or changing trust epoch", async () => {
    const invalid = baseOptions();
    invalid.initialize = vi.fn().mockResolvedValue(connection({ acknowledgedTrustEpoch: 0 }));
    await expect(collectInstalledSvnAnonymousStressCheckout(invalid)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_TRUST_EPOCH_INVALID",
    });

    const stale = baseOptions();
    stale.initialize = vi.fn().mockResolvedValue(connection({ currentTrustEpochs: [8] }));
    await expect(collectInstalledSvnAnonymousStressCheckout(stale)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_TRUST_EPOCH_INVALID",
    });

    const changed = baseOptions();
    changed.initialize = vi.fn().mockResolvedValue(connection({ currentTrustEpochs: [7, 7, 8] }));
    await expect(collectInstalledSvnAnonymousStressCheckout(changed)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_TRUST_EPOCH_INVALID",
    });
  });

  it("rejects a centrally built envelope if the trust epoch changes during construction", async () => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection({ currentTrustEpochs: [7, 8] }));
    await expect(collectInstalledSvnAnonymousStressCheckout(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_ENVELOPE_INVALID",
    });
  });

  it.each([
    ["a different target", { workingCopyPath: "C:/evidence/other", revision: 2 }],
    ["a different revision", { workingCopyPath: CHECKOUT_PATH, revision: 3 }],
  ])("rejects checkout result with %s", async (_description, response) => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection({
      sendRequest: vi.fn().mockResolvedValue(response),
    }));
    await expect(collectInstalledSvnAnonymousStressCheckout(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_CHECKOUT_INVALID",
    });
  });

  it("rejects malformed counters and any authentication activity", async () => {
    const malformed = baseOptions();
    malformed.authActivity = () => ({
      credentialRequests: -1,
      credentialSettlements: 0,
      certificateRequests: 0,
    });
    await expect(collectInstalledSvnAnonymousStressCheckout(malformed)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_AUTH_ACTIVITY_INVALID",
    });
    expect(malformed.initialize).not.toHaveBeenCalled();

    const activity = baseOptions();
    let readCount = 0;
    activity.authActivity = () => ({
      credentialRequests: readCount++ === 0 ? 0 : 1,
      credentialSettlements: 0,
      certificateRequests: 0,
    });
    await expect(collectInstalledSvnAnonymousStressCheckout(activity)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_AUTH_ACTIVITY_INVALID",
    });
  });
});

function baseOptions(): InstalledSvnAnonymousStressCheckoutOptions {
  return {
    expectedToken: TOKEN,
    request: request(),
    extensionHostSessionSha256: EXTENSION_HOST_SESSION_SHA256,
    initialize: vi.fn().mockResolvedValue(connection()),
    authActivity: () => ({ credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 }),
  };
}

function request(): Record<string, unknown> {
  return {
    token: TOKEN,
    repositoryUrl: REPOSITORY_URL,
    checkoutPath: CHECKOUT_PATH,
    checkoutRevision: 2,
    operationId: OPERATION_ID,
  };
}

interface ConnectionOverrides {
  protocolMajor?: number;
  protocolMinor?: number;
  acknowledgedTrustEpoch?: number;
  currentTrustEpochs?: number[];
  remoteSubmissionEnabled?: boolean;
  capabilities?: Partial<BackendConnection["initializeResult"]["capabilities"]>;
  sendRequest?: ReturnType<typeof vi.fn>;
}

function connection(overrides: ConnectionOverrides = {}): Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
> {
  const currentTrustEpochs = overrides.currentTrustEpochs ?? [7];
  let currentTrustRead = 0;
  const currentRemoteTrustEpoch = vi.fn(() => {
    const value = currentTrustEpochs[Math.min(currentTrustRead, currentTrustEpochs.length - 1)];
    currentTrustRead += 1;
    return value!;
  });
  return {
    initializeResult: {
      protocol: { major: overrides.protocolMajor ?? 1, minor: overrides.protocolMinor ?? 35 },
      acknowledgedTrustEpoch: overrides.acknowledgedTrustEpoch ?? 7,
      capabilities: {
        realLibsvnBridge: true,
        repositoryCheckout: true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        remoteSvnAnonymous: true,
        ...overrides.capabilities,
      },
    } as BackendConnection["initializeResult"],
    isRemoteSubmissionEnabled: () => overrides.remoteSubmissionEnabled ?? true,
    currentRemoteTrustEpoch,
    sendRequest: (overrides.sendRequest ?? vi.fn().mockResolvedValue({
      workingCopyPath: CHECKOUT_PATH,
      revision: 2,
    })) as BackendConnection["sendRequest"],
  };
}

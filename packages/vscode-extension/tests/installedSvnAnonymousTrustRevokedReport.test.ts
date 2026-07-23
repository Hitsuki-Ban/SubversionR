import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousTrustRevokedReport,
  type InstalledSvnAnonymousTrustRevokedReportOptions,
} from "../src/diagnostics/installedSvnAnonymousTrustRevokedReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "installed-i6-trust-revoked-token";
const REPOSITORY_URL = "svn://127.0.0.1:3692/repo/trunk";
const WORKING_COPY_PATH = "C:\\evidence\\i6-trust-revoked-wc";
const FIXTURE_STATE_PATH = "C:\\evidence\\i6-trust-revoked-fixture-state.json";
const OPERATION_ID = "61000000-0000-4000-8000-000000000001";
const REPOSITORY_ID = "repo-uuid:C:\\evidence\\i6-trust-revoked-wc";

describe("installed SVN anonymous trust-revoked report", () => {
  it("proves ordered revocation, stale epoch rejection, zero network, and same-session local recovery", async () => {
    const options = baseOptions();
    const active = trustRevokedConnection();
    options.initialize = vi.fn().mockResolvedValue(active.connection);

    const report = await collectInstalledSvnAnonymousTrustRevokedReport(options);

    expect(report).toEqual({
      schema: "subversionr.release.m8-i6-installed-vsix-trust-revoked.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousTrustRevokedReport",
      scenario: "trustRevoked",
      settlement: {
        code: "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH",
        category: "state",
        messageKey: "error.remote.trustEpochMismatch",
        retryable: false,
        remoteFailure: {
          category: "configuration",
          reason: "remoteConfigurationInvalid",
          cleanupAppropriate: false,
        },
      },
      diagnostics: null,
      remoteSubmissionDisabled: true,
      localSnapshotAfterTrustRevocation: true,
      protocol: { major: 1, minor: 35 },
      trust: {
        initialAcknowledgedEpoch: 1,
        revokedAcknowledgedEpoch: 2,
        submissionEnabled: false,
        consistent: true,
      },
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      repositorySession: { opened: true, closed: true },
      diagnosticsRedacted: true,
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    });
    expect(active.connection.updateWorkspaceTrust).toHaveBeenCalledWith(false);
    expect(active.calls()).toEqual(["update:false", "status/checkRemote", "status/getSnapshot", "diagnostics/get"]);
    expect(options.readFixtureState).toHaveBeenCalledTimes(2);
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("rejects missing authorization, non-exact requests, and relative fixture paths before initialization", async () => {
    for (const requestValue of [
      request("wrong-token"),
      { ...request(), extra: true },
      { ...request(), fixtureStatePath: "relative-state.json" },
    ]) {
      const options = baseOptions();
      options.request = requestValue;
      await expect(collectInstalledSvnAnonymousTrustRevokedReport(options)).rejects.toBeDefined();
      expect(options.initialize).not.toHaveBeenCalled();
    }
  });

  it("fails before initialization unless the controlled fixture is exact and untouched", async () => {
    for (const state of [
      fixtureState({ connections: 1 }),
      fixtureState({ authRequestSent: 1 }),
      fixtureState({ port: 3693 }),
      { ...fixtureState(), extra: true },
    ]) {
      const options = baseOptions();
      options.readFixtureState = vi.fn().mockResolvedValue(state);
      await expect(collectInstalledSvnAnonymousTrustRevokedReport(options)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_FIXTURE_STATE_INVALID",
      });
      expect(options.initialize).not.toHaveBeenCalled();
    }
  });

  it("requires exact initial epoch one and constructs the stale envelope before opening the working copy", async () => {
    for (const initial of [
      { epoch: 2, submissionEnabled: true },
      { epoch: 1, submissionEnabled: false },
    ]) {
      const options = baseOptions();
      const active = trustRevokedConnection(initial);
      options.initialize = vi.fn().mockResolvedValue(active.connection);
      await expect(collectInstalledSvnAnonymousTrustRevokedReport(options)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_TRUST_EPOCH_INVALID",
      });
      expect(options.openWorkingCopy).not.toHaveBeenCalled();
    }
  });

  it("fails closed unless revocation acknowledges epoch two and disables submission", async () => {
    for (const active of [
      trustRevokedConnection({ acknowledgedEpoch: 3 }),
      trustRevokedConnection({ keepSubmissionEnabled: true }),
      trustRevokedConnection({ revokedEpoch: 1 }),
    ]) {
      const options = baseOptions();
      options.initialize = vi.fn().mockResolvedValue(active.connection);
      await expect(collectInstalledSvnAnonymousTrustRevokedReport(options)).rejects.toBeDefined();
      expect(active.connection.sendRequest).not.toHaveBeenCalledWith("status/checkRemote", expect.anything());
      expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
    }
  });

  it("requires the exact daemon trust taxonomy and never accepts a successful stale request", async () => {
    for (const staleSettlement of [
      "success" as const,
      new JsonRpcStreamError({
        code: "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH",
        category: "configuration",
        messageKey: "error.remote.trustEpochMismatch",
        args: { remoteFailure: { category: "configuration", reason: "remoteConfigurationInvalid", cleanupAppropriate: false } },
        retryable: false,
        diagnostics: null,
      }),
      new JsonRpcStreamError({
        code: "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH",
        category: "state",
        messageKey: "error.remote.trustEpochMismatch",
        args: { remoteFailure: { category: "configuration", reason: "trustRevoked", cleanupAppropriate: false } },
        retryable: false,
        diagnostics: null,
      }),
    ]) {
      const options = baseOptions();
      const active = trustRevokedConnection({ staleSettlement });
      options.initialize = vi.fn().mockResolvedValue(active.connection);
      await expect(collectInstalledSvnAnonymousTrustRevokedReport(options)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_SETTLEMENT_INVALID",
      });
    }
  });

  it("rejects unusable local recovery, diagnostics leaks, authentication activity, and fixture drift", async () => {
    const invalidSnapshot = baseOptions();
    const snapshotConnection = trustRevokedConnection({ snapshotSource: "libsvn-remote" });
    invalidSnapshot.initialize = vi.fn().mockResolvedValue(snapshotConnection.connection);
    await expect(collectInstalledSvnAnonymousTrustRevokedReport(invalidSnapshot)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_LOCAL_SNAPSHOT_INVALID",
    });

    const leakedDiagnostics = baseOptions();
    const diagnosticsConnection = trustRevokedConnection({ diagnostics: { ...currentDiagnostics(), leaked: OPERATION_ID } });
    leakedDiagnostics.initialize = vi.fn().mockResolvedValue(diagnosticsConnection.connection);
    await expect(collectInstalledSvnAnonymousTrustRevokedReport(leakedDiagnostics)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_DIAGNOSTICS_LEAK",
    });

    const escapedWindowsPath = baseOptions();
    const escapedWindowsPathConnection = trustRevokedConnection({
      diagnostics: { ...currentDiagnostics(), leaked: WORKING_COPY_PATH },
    });
    escapedWindowsPath.initialize = vi.fn().mockResolvedValue(escapedWindowsPathConnection.connection);
    await expect(collectInstalledSvnAnonymousTrustRevokedReport(escapedWindowsPath)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_DIAGNOSTICS_LEAK",
    });

    const auth = { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 };
    const authOptions = baseOptions(auth);
    const authConnection = trustRevokedConnection({ onDiagnostics: () => { auth.credentialRequests = 1; } });
    authOptions.initialize = vi.fn().mockResolvedValue(authConnection.connection);
    await expect(collectInstalledSvnAnonymousTrustRevokedReport(authOptions)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_AUTH_ACTIVITY_INVALID",
    });

    const fixtureDrift = baseOptions();
    fixtureDrift.readFixtureState = vi.fn()
      .mockResolvedValueOnce(fixtureState())
      .mockResolvedValueOnce(fixtureState({ commandsReceived: 1 }));
    const driftConnection = trustRevokedConnection();
    fixtureDrift.initialize = vi.fn().mockResolvedValue(driftConnection.connection);
    await expect(collectInstalledSvnAnonymousTrustRevokedReport(fixtureDrift)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_FIXTURE_STATE_INVALID",
    });
  });
});

function baseOptions(
  auth = { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
): InstalledSvnAnonymousTrustRevokedReportOptions {
  const calls: string[] = [];
  return {
    expectedToken: TOKEN,
    request: request(),
    initialize: vi.fn().mockResolvedValue(trustRevokedConnection().connection),
    openWorkingCopy: vi.fn(async () => {
      calls.push("open");
      return session();
    }),
    closeRepository: vi.fn().mockResolvedValue(undefined),
    authActivity: vi.fn(() => ({ ...auth })),
    readFixtureState: vi.fn().mockResolvedValue(fixtureState()),
  };
}

function request(token = TOKEN): Record<string, unknown> {
  return {
    token,
    repositoryUrl: REPOSITORY_URL,
    workingCopyPath: WORKING_COPY_PATH,
    operationId: OPERATION_ID,
    fixtureStatePath: FIXTURE_STATE_PATH,
  };
}

function trustRevokedConnection(options: {
  epoch?: number;
  submissionEnabled?: boolean;
  acknowledgedEpoch?: number;
  revokedEpoch?: number;
  keepSubmissionEnabled?: boolean;
  staleSettlement?: "success" | unknown;
  snapshotSource?: string;
  diagnostics?: unknown;
  onDiagnostics?: () => void;
} = {}): { connection: BackendConnection; calls(): string[] } {
  let epoch = options.epoch ?? 1;
  let submissionEnabled = options.submissionEnabled ?? true;
  const calls: string[] = [];
  const updateWorkspaceTrust = vi.fn(async (trusted: boolean) => {
    calls.push(`update:${String(trusted)}`);
    epoch = options.revokedEpoch ?? 2;
    submissionEnabled = options.keepSubmissionEnabled === true ? true : trusted;
    return options.acknowledgedEpoch ?? 2;
  });
  const sendRequest = vi.fn(async (method: string, params: unknown) => {
    calls.push(method);
    if (method === "status/checkRemote") {
      expect(params).toEqual({
        repositoryId: REPOSITORY_ID,
        epoch: 7,
        remote: expectedRemoteEnvelope(),
      });
      if (options.staleSettlement === "success") {
        return {};
      }
      throw "staleSettlement" in options ? options.staleSettlement : trustEpochMismatchError();
    }
    if (method === "status/getSnapshot") {
      return {
        repositoryId: REPOSITORY_ID,
        epoch: 7,
        generation: 1,
        completeness: "complete",
        identity: session().identity,
        localEntries: [],
        remoteEntries: [],
        summary: { localChanges: 0, remoteChanges: 0, conflicts: 0, unversioned: 0 },
        timestamp: "2026-07-19T00:00:00Z",
        source: options.snapshotSource ?? "libsvn-local",
      };
    }
    expect(method).toBe("diagnostics/get");
    expect(params).toEqual({});
    options.onDiagnostics?.();
    return options.diagnostics ?? currentDiagnostics();
  });
  return {
    connection: {
      initializeResult: initializeResult(options.epoch ?? 1),
      sendRequest,
      isRemoteSubmissionEnabled: () => submissionEnabled,
      currentRemoteTrustEpoch: () => epoch,
      updateWorkspaceTrust,
    } as unknown as BackendConnection,
    calls: () => calls,
  };
}

function trustEpochMismatchError(): JsonRpcStreamError {
  return new JsonRpcStreamError({
    code: "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH",
    category: "state",
    messageKey: "error.remote.trustEpochMismatch",
    args: {
      remoteFailure: {
        category: "configuration",
        reason: "remoteConfigurationInvalid",
        cleanupAppropriate: false,
      },
    },
    retryable: false,
    diagnostics: null,
  });
}

function fixtureState(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1",
    pid: 1234,
    port: 3692,
    suppliedAuthorityPort: 0,
    scenario: "greeting-stall",
    status: "ready",
    connections: 0,
    suppliedAuthorityConnections: 0,
    greetingSent: 0,
    clientResponseReceived: 0,
    authRequestSent: 0,
    reposInfoSent: 0,
    commandsReceived: 0,
    followupContacts: 0,
    ...overrides,
  };
}

function session(): RepositorySession {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 7,
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: REPOSITORY_URL,
      workingCopyRoot: WORKING_COPY_PATH,
      workspaceScopeRoot: WORKING_COPY_PATH,
      format: 31,
    },
    watchScope: {
      repositoryId: REPOSITORY_ID,
      epoch: 7,
      workingCopyRoot: WORKING_COPY_PATH,
      boundaryRoots: [],
      pathCase: "case-insensitive",
    },
  };
}

function expectedRemoteEnvelope(): Record<string, unknown> {
  return {
    version: 1,
    operationId: OPERATION_ID,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: 30_000,
    workspaceTrust: "trusted",
    trustEpoch: 1,
    profile: {
      schema: "subversionr.remote-profile.v1",
      profileId: "installed-i6-svn-anonymous-trust-revoked",
      authority: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3692 },
      serverAuth: "anonymous",
      serverAccount: "none",
      serverCredentialPersistence: "secretStorage",
      proxy: "none",
      ssh: "none",
      redirectPolicy: "rejectAll",
    },
    expectedOrigin: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3692 },
  };
}

function initializeResult(acknowledgedTrustEpoch: number): BackendConnection["initializeResult"] {
  return {
    protocol: { major: 1, minor: 35 },
    capabilities: {
      realLibsvnBridge: true,
      repositoryOpen: true,
      repositoryClose: true,
      statusSnapshot: true,
      statusRemoteCheck: true,
      remoteOperationEnvelope: true,
      remoteWorkerIsolation: true,
      remoteConnectionState: true,
      remoteSvnAnonymous: true,
      diagnosticsGet: true,
    },
    acknowledgedTrustEpoch,
  } as BackendConnection["initializeResult"];
}

function currentDiagnostics(): Record<string, unknown> {
  return {
    source: "subversionr-daemon",
    protocol: { major: 1, minor: 35 },
    capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true, statusSnapshot: true },
  };
}

import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousRecoveryBlockedReport,
  type InstalledSvnAnonymousRecoveryBlockedReportOptions,
} from "../src/diagnostics/installedSvnAnonymousRecoveryBlockedReport";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "installed-recovery-blocked-token";
const FAULT_URL = "svn://127.0.0.1:3791/repo/trunk";
const HEALTHY_URL = "svn://127.0.0.1:3792/repo/trunk";
const UNRELATED_URL = "svn://127.0.0.1:3793/unrelated/trunk";
const TARGET = "C:\\evidence\\recovery-blocked-target";
const UNRELATED_TARGET = "C:\\evidence\\unrelated-recovery-target";
const ORIGIN = "60000000-0000-4000-8000-000000000001";
const RETRY = "60000000-0000-4000-8000-000000000002";
const FRESH = "60000000-0000-4000-8000-000000000003";
const TARGET_SHA = "a".repeat(64);
const STATE_PATH = "C:\\evidence\\fault-state.json";

describe("installed SVN anonymous recovery-blocked report", () => {
  it("records the timeout origin and terminal blocked settlement while retaining one blocked journal entry", async () => {
    const sendRequest = vi.fn(async (method: string): Promise<unknown> => {
      if (method === "repository/checkout") throw blockedOriginError();
      expect(method).toBe("remote/listCheckoutTargetRecoveries");
      return { entries: [blockedEntry()] };
    });
    const options = baseOptions(armRequest(), sendRequest);

    const report = await collectInstalledSvnAnonymousRecoveryBlockedReport(options);

    expect(report).toMatchObject({
      schema: "subversionr.release.m8-i6-installed-vsix-recovery-blocked.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousRecoveryBlockedReport",
      phase: "arm",
      originCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
      originReason: "operationDeadlineExceeded",
      settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
      settlementReason: "remoteRecoveryBlocked",
      blockedEntryCount: 1,
      blockedEntryState: "blocked",
      blockedTargetPathSha256: sha256(TARGET),
      blockedOriginOperationIdSha256: sha256(ORIGIN),
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      diagnosticsRedacted: true,
    });
    expect(sendRequest.mock.calls.map(([method]) => method)).toEqual([
      "repository/checkout",
      "remote/listCheckoutTargetRecoveries",
    ]);
  });

  it("serves an unrelated repository without changing the restored block, then confirms exactly and checks out the original target", async () => {
    let listCalls = 0;
    const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
      if (method === "remote/listCheckoutTargetRecoveries") {
        listCalls += 1;
        return { entries: listCalls <= 3 ? [blockedEntry()] : [] };
      }
      if (method === "repository/checkout") {
        const request = params as { url: string; targetPath: string };
        if (request.targetPath === UNRELATED_TARGET) {
          expect(request.url).toBe(UNRELATED_URL);
          return { workingCopyPath: UNRELATED_TARGET, revision: 2 };
        }
        if (listCalls === 2) throw localBlockedError();
        return { workingCopyPath: TARGET, revision: 2 };
      }
      if (method === "remote/confirmCheckoutTargetDisposition") {
        expect(params).toEqual({
          targetPath: TARGET,
          targetSha256: TARGET_SHA,
          originOperationId: ORIGIN,
          confirmation: "reviewedAndResolved",
        });
        return { released: true, targetSha256: TARGET_SHA, originOperationId: ORIGIN };
      }
      throw new Error(`unexpected method ${method}`);
    });
    const readFixtureState = vi.fn().mockResolvedValue(fixtureState());
    const options = baseOptions(recoverRequest(), sendRequest);
    options.readFixtureState = readFixtureState;

    const report = await collectInstalledSvnAnonymousRecoveryBlockedReport(options);

    expect(report).toMatchObject({
      phase: "recover",
      outcome: "Blocked",
      stableCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
      reason: "remoteRecoveryBlocked",
      restartRestoredBlocked: true,
      unrelatedRepositoryServed: true,
      blockedEntryUnchangedAfterUnrelated: true,
      blockedJournalUnchangedAfterUnrelated: true,
      blockedJournalBytesSha256BeforeUnrelated: sha256("blocked-journal"),
      blockedJournalBytesSha256AfterUnrelated: sha256("blocked-journal"),
      unrelatedCheckoutRevision: 2,
      unrelatedTargetPathSha256: sha256(UNRELATED_TARGET),
      automaticClear: false,
      requiredConfirmation: "reviewedAndResolved",
      armedTargetPathSha256: sha256(TARGET),
      confirmedTargetPathSha256: sha256(TARGET),
      armedOriginOperationIdSha256: sha256(ORIGIN),
      confirmedOriginOperationIdSha256: sha256(ORIGIN),
      confirmedEntryRemoved: true,
      fixtureCountersUnchangedOnBlockedRetry: true,
      targetDisposition: "confirmedAbsent",
      subsequentCheckoutPassed: true,
      checkoutRevision: 2,
    });
    expect(readFixtureState).toHaveBeenCalledTimes(2);
    expect(options.readRecoveryJournalBytes).toHaveBeenCalledTimes(2);
    expect(sendRequest.mock.calls.map(([method]) => method)).toEqual([
      "remote/listCheckoutTargetRecoveries",
      "repository/checkout",
      "remote/listCheckoutTargetRecoveries",
      "repository/checkout",
      "remote/listCheckoutTargetRecoveries",
      "remote/confirmCheckoutTargetDisposition",
      "remote/listCheckoutTargetRecoveries",
      "repository/checkout",
      "remote/listCheckoutTargetRecoveries",
    ]);
  });

  it("fails closed when the blocked retry creates a target before confirmation", async () => {
    let checkoutCalls = 0;
    const sendRequest = vi.fn(async (method: string): Promise<unknown> => {
      if (method === "remote/listCheckoutTargetRecoveries") {
        return { entries: [blockedEntry()] };
      }
      if (method === "repository/checkout") {
        checkoutCalls += 1;
        if (checkoutCalls === 1) return { workingCopyPath: UNRELATED_TARGET, revision: 2 };
        throw localBlockedError();
      }
      throw new Error(`unexpected method ${method}`);
    });
    const options = baseOptions(recoverRequest(), sendRequest);
    options.targetPathExists = vi.fn().mockReturnValue(true);

    await expect(collectInstalledSvnAnonymousRecoveryBlockedReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_TARGET_DISPOSITION_INVALID",
    });
    expect(options.targetPathExists).toHaveBeenCalledWith(TARGET);
    expect(sendRequest).not.toHaveBeenCalledWith(
      "remote/confirmCheckoutTargetDisposition",
      expect.anything(),
    );
  });

  it("fails closed if the blocked retry reaches the command-stall fixture", async () => {
    let listCalls = 0;
    let checkoutCalls = 0;
    const sendRequest = vi.fn(async (method: string): Promise<unknown> => {
      if (method === "remote/listCheckoutTargetRecoveries") {
        listCalls += 1;
        return { entries: [blockedEntry()] };
      }
      checkoutCalls += 1;
      if (checkoutCalls === 1) return { workingCopyPath: UNRELATED_TARGET, revision: 2 };
      throw localBlockedError();
    });
    const changed = { ...fixtureState(), followupContacts: 1 };
    const options = baseOptions(recoverRequest(), sendRequest);
    options.readFixtureState = vi.fn()
      .mockResolvedValueOnce(fixtureState())
      .mockResolvedValueOnce(changed);

    await expect(collectInstalledSvnAnonymousRecoveryBlockedReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_NETWORK_PROGRESS_INVALID",
    });
    expect(listCalls).toBe(2);
  });

  it("fails closed when the blocked entry changes after the unrelated checkout", async () => {
    let listCalls = 0;
    const sendRequest = vi.fn(async (method: string): Promise<unknown> => {
      if (method === "remote/listCheckoutTargetRecoveries") {
        listCalls += 1;
        return {
          entries: [listCalls === 1 ? blockedEntry() : { ...blockedEntry(), targetSha256: "b".repeat(64) }],
        };
      }
      if (method === "repository/checkout") {
        return { workingCopyPath: UNRELATED_TARGET, revision: 2 };
      }
      throw new Error(`unexpected method ${method}`);
    });

    await expect(
      collectInstalledSvnAnonymousRecoveryBlockedReport(baseOptions(recoverRequest(), sendRequest)),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_ENTRY_CHANGED_AFTER_UNRELATED",
    });
  });

  it("fails closed when the raw recovery journal changes during the unrelated checkout", async () => {
    const sendRequest = vi.fn(async (method: string): Promise<unknown> => {
      if (method === "remote/listCheckoutTargetRecoveries") return { entries: [blockedEntry()] };
      if (method === "repository/checkout") {
        return { workingCopyPath: UNRELATED_TARGET, revision: 2 };
      }
      throw new Error(`unexpected method ${method}`);
    });
    const options = baseOptions(recoverRequest(), sendRequest);
    options.readRecoveryJournalBytes = vi.fn()
      .mockResolvedValueOnce(Buffer.from("journal-before", "utf8"))
      .mockResolvedValueOnce(Buffer.from("journal-after", "utf8"));

    await expect(collectInstalledSvnAnonymousRecoveryBlockedReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_JOURNAL_CHANGED_AFTER_UNRELATED",
    });
  });

  it("fails closed when the unrelated checkout fails", async () => {
    const sendRequest = vi.fn(async (method: string): Promise<unknown> => {
      if (method === "remote/listCheckoutTargetRecoveries") return { entries: [blockedEntry()] };
      if (method === "repository/checkout") throw new Error("controlled unrelated failure");
      throw new Error(`unexpected method ${method}`);
    });

    await expect(
      collectInstalledSvnAnonymousRecoveryBlockedReport(baseOptions(recoverRequest(), sendRequest)),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_UNRELATED_CHECKOUT_INVALID",
    });
  });

  it("fails closed when the unrelated checkout reports a different working-copy path", async () => {
    const sendRequest = vi.fn(async (method: string): Promise<unknown> => {
      if (method === "remote/listCheckoutTargetRecoveries") return { entries: [blockedEntry()] };
      if (method === "repository/checkout") {
        return { workingCopyPath: "C:\\evidence\\wrong-unrelated-target", revision: 2 };
      }
      throw new Error(`unexpected method ${method}`);
    });

    await expect(
      collectInstalledSvnAnonymousRecoveryBlockedReport(baseOptions(recoverRequest(), sendRequest)),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_UNRELATED_CHECKOUT_INVALID",
    });
  });

  it("fails closed when the unrelated checkout does not report the deterministic r2", async () => {
    const sendRequest = vi.fn(async (method: string): Promise<unknown> => {
      if (method === "remote/listCheckoutTargetRecoveries") return { entries: [blockedEntry()] };
      if (method === "repository/checkout") {
        return { workingCopyPath: UNRELATED_TARGET, revision: 3 };
      }
      throw new Error(`unexpected method ${method}`);
    });

    await expect(
      collectInstalledSvnAnonymousRecoveryBlockedReport(baseOptions(recoverRequest(), sendRequest)),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_UNRELATED_CHECKOUT_INVALID",
    });
  });

  it("rejects missing tokens, unexpected fields, operation reuse, and non-reviewed timeouts before initialization", async () => {
    for (const request of [
      armRequest({ token: "wrong" }),
      armRequest({ extra: true }),
      armRequest({ timeoutMs: 4999 }),
      recoverRequest({ retryOperationId: ORIGIN }),
      recoverRequest({ unrelatedTargetPath: TARGET }),
      recoverRequest({ unrelatedRepositoryUrl: undefined }),
      recoverRequest({ unrelatedRepositoryUrl: HEALTHY_URL }),
      recoverRequest({ unrelatedRepositoryUrl: "svn://127.0.0.1:3793/repo/trunk" }),
    ]) {
      const options = baseOptions(request, vi.fn());
      await expect(collectInstalledSvnAnonymousRecoveryBlockedReport(options)).rejects.toMatchObject({
        code: expect.stringMatching(/^SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_/u),
      });
      expect(options.initialize).not.toHaveBeenCalled();
    }
  });
});

function baseOptions(
  request: Record<string, unknown>,
  sendRequest: (method: string, params: unknown) => Promise<unknown>,
): InstalledSvnAnonymousRecoveryBlockedReportOptions {
  return {
    expectedToken: TOKEN,
    request,
    initialize: vi.fn().mockResolvedValue(connection(sendRequest)),
    authActivity: () => ({ credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 }),
    readFixtureState: vi.fn().mockResolvedValue(fixtureState()),
    readRecoveryJournalBytes: vi.fn().mockResolvedValue(Buffer.from("blocked-journal", "utf8")),
    targetPathExists: vi.fn().mockReturnValue(false),
  };
}

function armRequest(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    token: TOKEN,
    phase: "arm",
    repositoryUrl: FAULT_URL,
    targetPath: TARGET,
    operationId: ORIGIN,
    timeoutMs: 5000,
    ...overrides,
  };
}

function recoverRequest(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    token: TOKEN,
    phase: "recover",
    faultRepositoryUrl: FAULT_URL,
    healthyRepositoryUrl: HEALTHY_URL,
    unrelatedRepositoryUrl: UNRELATED_URL,
    unrelatedTargetPath: UNRELATED_TARGET,
    targetPath: TARGET,
    operationId: ORIGIN,
    retryOperationId: RETRY,
    freshOperationId: FRESH,
    fixtureStatePath: STATE_PATH,
    timeoutMs: 300_000,
    ...overrides,
  };
}

function blockedEntry(): Record<string, unknown> {
  return { targetPath: TARGET, targetSha256: TARGET_SHA, originOperationId: ORIGIN, state: "blocked" };
}

function fixtureState(): Record<string, unknown> {
  return {
    schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1",
    scenario: "command-stall",
    connections: 1,
    suppliedAuthorityConnections: 0,
    greetingSent: 1,
    clientResponseReceived: 1,
    authRequestSent: 1,
    reposInfoSent: 1,
    commandsReceived: 1,
    followupContacts: 0,
  };
}

function connection(
  sendRequest: (method: string, params: unknown) => Promise<unknown>,
): Pick<BackendConnection, "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"> {
  return {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      capabilities: {
        realLibsvnBridge: true,
        repositoryCheckout: true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        remoteSvnAnonymous: true,
      },
      acknowledgedTrustEpoch: 7,
    } as BackendConnection["initializeResult"],
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => 7,
    sendRequest: sendRequest as BackendConnection["sendRequest"],
  };
}

function blockedOriginError(): JsonRpcStreamError {
  return rpcError(
    { originFailureCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", remoteFailure: remoteFailure() },
  );
}

function localBlockedError(): JsonRpcStreamError {
  return rpcError({});
}

function rpcError(args: Record<string, unknown>): JsonRpcStreamError {
  return new JsonRpcStreamError({
    code: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    category: "state",
    messageKey: "error.remote.recoveryBlocked",
    args,
    retryable: false,
    diagnostics: null,
  });
}

function remoteFailure(): Record<string, unknown> {
  return { category: "recovery", reason: "remoteRecoveryBlocked", cleanupAppropriate: false };
}

function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

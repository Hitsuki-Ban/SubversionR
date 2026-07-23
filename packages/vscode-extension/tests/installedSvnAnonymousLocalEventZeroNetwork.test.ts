import { afterEach, describe, expect, it, vi } from "vitest";
import {
  InstalledSvnAnonymousLocalEventZeroNetworkObserver,
  type InstalledSvnAnonymousLocalEventZeroNetworkCounters,
} from "../src/diagnostics/installedSvnAnonymousLocalEventZeroNetwork";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import type { VscodeSourceControlSnapshot } from "../src/scm/vscodeSourceControlPresenter";
import type { DirtyPathPipeline } from "../src/status/dirtyPathPipeline";
import {
  RepositoryWatcherService,
  type AcceptedRepositoryWatcherEvent,
  type RepositoryFileWatcher,
} from "../src/status/repositoryWatcherService";
import { StatusRefreshCoverageStore } from "../src/status/statusRefreshCoverageStore";
import type { CompletedStatusRefreshCoverage } from "../src/status/statusRefreshScheduler";

const TOKEN = "local-event-zero-network-token";
const WORKING_COPY_PATH = "C:\\fixture\\wc";
const RELATIVE_PATH = ".subversionr-local-event-sentinel.txt";

afterEach(() => {
  vi.useRealTimers();
});

describe("InstalledSvnAnonymousLocalEventZeroNetworkObserver", () => {
  it("reports a real accepted same-path watcher event, matching refresh coverage, changed projection, and zero network activity", async () => {
    const harness = observerHarness();
    const armed = await harness.observer.arm(armRequest());

    expect(armed).toEqual({
      schema: "subversionr.release.m8-i6-installed-svn-anonymous-local-event-zero-network.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousLocalEventZeroNetwork",
      status: "armed",
      cell: "localEventZeroNetwork",
      surface: "installed",
      observationId: "local-event-zero-network-1",
      target: { path: RELATIVE_PATH, depth: "empty", reason: "fileChanged" },
    });
    expect(harness.openRequests).toEqual([{ path: WORKING_COPY_PATH, pathCase: "case-insensitive" }]);

    const reportPromise = harness.observer.awaitReport(awaitRequest(armed.observationId));
    harness.watcherEvents.emit({
      repositoryId: "repo-uuid:C:/fixture/wc",
      epoch: 7,
      absolutePath: `C:/fixture/wc/${RELATIVE_PATH}`,
      kind: "changed",
      timestamp: 100,
    });
    harness.counters.statusRefreshRequestCount += 1;
    harness.coverage.emit(coverageRecord());

    await expect(reportPromise).resolves.toEqual({
      schema: "subversionr.release.m8-i6-installed-svn-anonymous-local-event-zero-network.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousLocalEventZeroNetwork",
      status: "passed",
      cell: "localEventZeroNetwork",
      surface: "installed",
      watcherObserved: true,
      watcherEventKinds: ["changed"],
      target: { path: RELATIVE_PATH, depth: "empty", reason: "fileChanged" },
      projectionObserved: true,
      statusRefreshRequestDelta: 1,
      remoteStatusRequestDelta: 0,
      reconcileRequestDelta: 0,
      authActivity: {
        credentialRequests: 0,
        credentialSettlements: 0,
        certificateRequests: 0,
      },
      diagnosticsRedacted: true,
    });
    expect(harness.watcherEvents.listenerCount()).toBe(0);
    expect(harness.coverage.listenerCount()).toBe(0);
    expect(harness.closeCalls).toEqual(["repo-uuid:C:/fixture/wc"]);
    const serialized = JSON.stringify(await reportPromise);
    expect(serialized).not.toContain(TOKEN);
    expect(serialized).not.toContain(WORKING_COPY_PATH);
    expect(serialized).not.toContain("repo-uuid:C:/fixture/wc");
    expect(serialized).not.toContain(armed.observationId);
  });

  it("requires watcher-before-coverage causal ordering without synthetic events", async () => {
    const harness = observerHarness();
    const armed = await harness.observer.arm(armRequest());
    let settled = false;
    const reportPromise = harness.observer.awaitReport(awaitRequest(armed.observationId)).finally(() => {
      settled = true;
    });

    harness.counters.statusRefreshRequestCount += 1;
    harness.coverage.emit(coverageRecord());
    harness.watcherEvents.emit({
      repositoryId: "repo-uuid:C:/fixture/wc",
      epoch: 7,
      absolutePath: "C:/fixture/wc/different.txt",
      kind: "changed",
      timestamp: 100,
    });
    await Promise.resolve();
    expect(settled).toBe(false);

    harness.watcherEvents.emit({
      repositoryId: "repo-uuid:C:/fixture/wc",
      epoch: 7,
      absolutePath: `C:/fixture/wc/${RELATIVE_PATH}`,
      kind: "changed",
      timestamp: 101,
    });

    await Promise.resolve();
    expect(settled).toBe(false);
    harness.coverage.emit(coverageRecord());

    await expect(reportPromise).resolves.toMatchObject({
      watcherObserved: true,
      watcherEventKinds: ["changed"],
      projectionObserved: true,
    });
  });

  it.each([
    ["missing expected token", undefined, armRequest(), "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_FORBIDDEN"],
    ["wrong token", TOKEN, { ...armRequest(), token: "wrong" }, "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_FORBIDDEN"],
    ["extra field", TOKEN, { ...armRequest(), extra: true }, "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID"],
    ["relative traversal", TOKEN, { ...armRequest(), relativePath: "../outside.txt" }, "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID"],
    ["SVN metadata", TOKEN, { ...armRequest(), relativePath: ".svn/wc.db" }, "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID"],
    ["relative working copy", TOKEN, { ...armRequest(), workingCopyPath: "fixture/wc" }, "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID"],
  ])("rejects %s", async (_name, expectedToken, request, code) => {
    const harness = observerHarness({ expectedToken });

    await expect(harness.observer.arm(request)).rejects.toMatchObject({ code });
    expect(harness.watcherEvents.listenerCount()).toBe(0);
    expect(harness.coverage.listenerCount()).toBe(0);
    expect(harness.closeCalls).toEqual([]);
  });

  it("requires a trusted workspace and validates the formally opened working-copy session", async () => {
    const untrusted = observerHarness({ workspaceTrusted: false });
    await expect(untrusted.observer.arm(armRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_WORKSPACE_UNTRUSTED",
    });

    const invalid = observerHarness({
      openSession: {
        ...session(),
        identity: { ...session().identity, workingCopyRoot: "C:\\fixture\\other" },
      },
    });
    await expect(invalid.observer.arm(armRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_SESSION_INVALID",
    });
    expect(invalid.closeCalls).toEqual(["repo-uuid:C:/fixture/wc"]);
  });

  it("allows only one active or unconsumed observation and validates the await observation id", async () => {
    const harness = observerHarness();
    const armed = await harness.observer.arm(armRequest());

    await expect(harness.observer.arm(armRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_ALREADY_ARMED",
    });
    await expect(
      harness.observer.awaitReport(awaitRequest("local-event-zero-network-2")),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_OBSERVATION_MISMATCH",
    });

    const reportPromise = harness.observer.awaitReport(awaitRequest(armed.observationId));
    await expect(
      harness.observer.awaitReport(awaitRequest(armed.observationId)),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_AWAIT_ALREADY_PENDING",
    });
    harness.observer.dispose();
    await expect(reportPromise).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DISPOSED",
    });
  });

  it("fails with a typed absolute-deadline timeout and clears both subscriptions", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-19T00:00:00Z"));
    const harness = observerHarness();
    const armed = await harness.observer.arm(armRequest({ timeoutMs: 1_000 }));
    const reportPromise = harness.observer.awaitReport(awaitRequest(armed.observationId));
    const timeoutAssertion = expect(reportPromise).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_TIMEOUT",
      category: "timeout",
    });

    await vi.advanceTimersByTimeAsync(1_000);

    await timeoutAssertion;
    expect(harness.watcherEvents.listenerCount()).toBe(0);
    expect(harness.coverage.listenerCount()).toBe(0);
    expect(harness.closeCalls).toEqual(["repo-uuid:C:/fixture/wc"]);
  });

  it("fails closed when projection or activity deltas do not prove the cell", async () => {
    const missingProjection = observerHarness({ snapshot: undefined });
    const first = await missingProjection.observer.arm(armRequest());
    const firstReport = missingProjection.observer.awaitReport(awaitRequest(first.observationId));
    emitSuccessfulCausalInputs(missingProjection);
    await expect(firstReport).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_PROJECTION_INVALID",
    });

    const networkActivity = observerHarness();
    const second = await networkActivity.observer.arm(armRequest());
    const secondReport = networkActivity.observer.awaitReport(awaitRequest(second.observationId));
    networkActivity.counters.statusRefreshRequestCount += 1;
    networkActivity.counters.remoteStatusRequestCount += 1;
    networkActivity.watcherEvents.emit(watcherEvent());
    networkActivity.coverage.emit(coverageRecord());
    await expect(secondReport).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_ACTIVITY_INVALID",
    });

    const wrongGeneration = observerHarness({
      snapshot: { ...sourceControlSnapshot(), generation: 12 },
    });
    const third = await wrongGeneration.observer.arm(armRequest());
    const thirdReport = wrongGeneration.observer.awaitReport(awaitRequest(third.observationId));
    emitSuccessfulCausalInputs(wrongGeneration);
    await expect(thirdReport).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_PROJECTION_INVALID",
    });
  });

  it("requires libsvn-local coverage, zero auth activity, and redacted candidate diagnostics", async () => {
    const wrongCoverage = observerHarness();
    const first = await wrongCoverage.observer.arm(armRequest());
    const firstReport = wrongCoverage.observer.awaitReport(awaitRequest(first.observationId));
    wrongCoverage.counters.statusRefreshRequestCount += 1;
    wrongCoverage.watcherEvents.emit(watcherEvent());
    wrongCoverage.coverage.emit({ ...coverageRecord(), source: "unexpected-source" });
    await expect(firstReport).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_COVERAGE_INVALID",
    });

    const missingScope = observerHarness();
    const missingScopeArm = await missingScope.observer.arm(armRequest());
    const missingScopeReport = missingScope.observer.awaitReport(awaitRequest(missingScopeArm.observationId));
    missingScope.counters.statusRefreshRequestCount += 1;
    missingScope.watcherEvents.emit(watcherEvent());
    missingScope.coverage.emit({ ...coverageRecord(), coverage: [] });
    await expect(missingScopeReport).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_COVERAGE_INVALID",
    });

    const auth = observerHarness();
    const second = await auth.observer.arm(armRequest());
    const secondReport = auth.observer.awaitReport(awaitRequest(second.observationId));
    auth.authActivity.credentialRequests += 1;
    emitSuccessfulCausalInputs(auth);
    await expect(secondReport).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_AUTH_ACTIVITY_INVALID",
    });

    const diagnostics = observerHarness({
      diagnostics: {
        ...candidateDiagnostics(),
        leakedPath: WORKING_COPY_PATH,
      },
    });
    const third = await diagnostics.observer.arm(armRequest());
    const thirdReport = diagnostics.observer.awaitReport(awaitRequest(third.observationId));
    emitSuccessfulCausalInputs(diagnostics);
    await expect(thirdReport).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DIAGNOSTICS_INVALID",
    });
  });

  it("requires an exact token-plus-observationId await request", async () => {
    const harness = observerHarness();
    const armed = await harness.observer.arm(armRequest());

    await expect(harness.observer.awaitReport({ token: TOKEN })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID",
    });
    await expect(
      harness.observer.awaitReport({ token: TOKEN, observationId: armed.observationId, extra: true }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID",
    });
    harness.observer.dispose();
  });

  it("does not return a successful terminal report until the formal repository close succeeds", async () => {
    const harness = observerHarness({ closeFails: true });
    const armed = await harness.observer.arm(armRequest());
    const report = harness.observer.awaitReport(awaitRequest(armed.observationId));

    emitSuccessfulCausalInputs(harness);

    await expect(report).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_CLOSE_FAILED",
    });
    expect(harness.closeCalls).toEqual(["repo-uuid:C:/fixture/wc"]);
    expect(harness.watcherEvents.listenerCount()).toBe(0);
    expect(harness.coverage.listenerCount()).toBe(0);
  });
});

describe("local event observer hooks", () => {
  it("publishes normalized absolute watcher events only after the real pipeline accepts them", () => {
    const watcher = new FakeRepositoryFileWatcher();
    const accept = vi.fn().mockReturnValueOnce(false).mockReturnValueOnce(true);
    const pipeline = {
      registerRepository: vi.fn(),
      unregisterRepository: vi.fn(),
      accept,
    } as unknown as DirtyPathPipeline;
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: () => watcher,
      now: vi.fn().mockReturnValueOnce(100).mockReturnValueOnce(101),
    });
    const events: AcceptedRepositoryWatcherEvent[] = [];
    service.onDidAcceptWatcherEvent((event) => events.push(event));
    service.registerRepository(session().watchScope);

    watcher.fireChanged("C:\\fixture\\wc\\ignored.txt");
    watcher.fireChanged(`C:\\fixture\\wc\\${RELATIVE_PATH}`);

    expect(accept).toHaveBeenCalledTimes(2);
    expect(events).toEqual([
      {
        repositoryId: "repo-uuid:C:/fixture/wc",
        epoch: 7,
        absolutePath: `C:/fixture/wc/${RELATIVE_PATH}`,
        kind: "changed",
        timestamp: 101,
      },
    ]);
  });

  it("publishes cloned completed coverage records and stops after disposal", () => {
    const store = new StatusRefreshCoverageStore();
    const received: CompletedStatusRefreshCoverage[] = [];
    const subscription = store.onDidRecordCompletedStatusRefreshCoverage((record) => {
      received.push(record);
      record.targets[0]!.path = "listener-mutated.txt";
    });

    store.recordCompletedStatusRefreshCoverage(coverageRecord());
    subscription.dispose();
    store.recordCompletedStatusRefreshCoverage(coverageRecord({ generation: 12 }));

    expect(received).toHaveLength(1);
    expect(store.getLastCompletedRefresh("repo-uuid:C:/fixture/wc", 7)?.targets[0]?.path).toBe(RELATIVE_PATH);
  });
});

interface ObserverHarness {
  observer: InstalledSvnAnonymousLocalEventZeroNetworkObserver;
  watcherEvents: EventSource<AcceptedRepositoryWatcherEvent>;
  coverage: EventSource<CompletedStatusRefreshCoverage>;
  counters: InstalledSvnAnonymousLocalEventZeroNetworkCounters;
  authActivity: {
    credentialRequests: number;
    credentialSettlements: number;
    certificateRequests: number;
  };
  closeCalls: string[];
  openRequests: Array<{ path: string; pathCase: "case-insensitive" }>;
}

function observerHarness(options: {
  expectedToken?: string | undefined;
  workspaceTrusted?: boolean;
  openSession?: RepositorySession;
  snapshot?: VscodeSourceControlSnapshot | undefined;
  diagnostics?: unknown;
  closeFails?: boolean;
} = {}): ObserverHarness {
  const watcherEvents = new EventSource<AcceptedRepositoryWatcherEvent>();
  const coverage = new EventSource<CompletedStatusRefreshCoverage>();
  const counters: InstalledSvnAnonymousLocalEventZeroNetworkCounters = {
    statusRefreshRequestCount: 10,
    remoteStatusRequestCount: 3,
    reconcileRequestCount: 4,
  };
  const authActivity = {
    credentialRequests: 2,
    credentialSettlements: 2,
    certificateRequests: 1,
  };
  const closeCalls: string[] = [];
  const openRequests: Array<{ path: string; pathCase: "case-insensitive" }> = [];
  const expectedToken = Object.prototype.hasOwnProperty.call(options, "expectedToken")
    ? options.expectedToken
    : TOKEN;
  const snapshot = Object.prototype.hasOwnProperty.call(options, "snapshot")
    ? options.snapshot
    : sourceControlSnapshot();
  return {
    watcherEvents,
    coverage,
    counters,
    authActivity,
    closeCalls,
    openRequests,
    observer: new InstalledSvnAnonymousLocalEventZeroNetworkObserver({
      expectedToken,
      workspaceTrusted: () => options.workspaceTrusted ?? true,
      pathCase: "case-insensitive",
      sessionService: {
        openWorkingCopy: async (request) => {
          openRequests.push(request as { path: string; pathCase: "case-insensitive" });
          return options.openSession ?? session();
        },
        closeRepository: async (repositoryId) => {
          closeCalls.push(repositoryId);
          if (options.closeFails) {
            throw new Error("close failed");
          }
        },
      },
      watcherService: { onDidAcceptWatcherEvent: (listener) => watcherEvents.subscribe(listener) },
      statusRefreshCoverage: {
        onDidRecordCompletedStatusRefreshCoverage: (listener) => coverage.subscribe(listener),
      },
      sourceControlSurface: { snapshotRepository: () => snapshot },
      counters: () => ({ ...counters }),
      authActivity: () => ({ ...authActivity }),
      collectDiagnostics: async () => options.diagnostics ?? candidateDiagnostics(),
    }),
  };
}

class EventSource<T> {
  private readonly listeners = new Set<(event: T) => void>();

  public subscribe(listener: (event: T) => void): { dispose(): void } {
    this.listeners.add(listener);
    return { dispose: () => this.listeners.delete(listener) };
  }

  public emit(event: T): void {
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  public listenerCount(): number {
    return this.listeners.size;
  }
}

class FakeRepositoryFileWatcher implements RepositoryFileWatcher {
  private readonly changed = new Set<(uri: { fsPath: string }) => void>();
  private readonly created = new Set<(uri: { fsPath: string }) => void>();
  private readonly deleted = new Set<(uri: { fsPath: string }) => void>();

  public onDidChange(listener: (uri: { fsPath: string }) => void): { dispose(): void } {
    this.changed.add(listener);
    return { dispose: () => this.changed.delete(listener) };
  }

  public onDidCreate(listener: (uri: { fsPath: string }) => void): { dispose(): void } {
    this.created.add(listener);
    return { dispose: () => this.created.delete(listener) };
  }

  public onDidDelete(listener: (uri: { fsPath: string }) => void): { dispose(): void } {
    this.deleted.add(listener);
    return { dispose: () => this.deleted.delete(listener) };
  }

  public dispose(): void {
    this.changed.clear();
    this.created.clear();
    this.deleted.clear();
  }

  public fireChanged(fsPath: string): void {
    for (const listener of this.changed) {
      listener({ fsPath });
    }
  }
}

function armRequest(overrides: Partial<{
  token: string;
  workingCopyPath: string;
  relativePath: string;
  timeoutMs: number;
}> = {}): Record<string, unknown> {
  return {
    token: overrides.token ?? TOKEN,
    workingCopyPath: overrides.workingCopyPath ?? WORKING_COPY_PATH,
    relativePath: overrides.relativePath ?? RELATIVE_PATH,
    timeoutMs: overrides.timeoutMs ?? 10_000,
  };
}

function awaitRequest(observationId: string): Record<string, unknown> {
  return { token: TOKEN, observationId };
}

function session(): RepositorySession {
  return {
    repositoryId: "repo-uuid:C:/fixture/wc",
    epoch: 7,
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: "svn://127.0.0.1:3690/repo",
      workingCopyRoot: WORKING_COPY_PATH,
      workspaceScopeRoot: WORKING_COPY_PATH,
      format: 31,
    },
    watchScope: {
      repositoryId: "repo-uuid:C:/fixture/wc",
      epoch: 7,
      workingCopyRoot: WORKING_COPY_PATH,
      pathCase: "case-insensitive",
    },
  };
}

function sourceControlSnapshot(): VscodeSourceControlSnapshot {
  return {
    repositoryId: "repo-uuid:C:/fixture/wc",
    epoch: 7,
    workingCopyRoot: WORKING_COPY_PATH,
    generation: 11,
    freshness: undefined,
    count: 1,
    statusBarCommands: undefined,
    inputBox: {
      placeholder: "SVN commit message",
      acceptInputCommand: "subversionr.commitAll",
      acceptInputCommandArguments: undefined,
    },
    groups: [
      {
        id: "changes",
        contextValue: undefined,
        hideWhenEmpty: true,
        count: 1,
        resources: [
          {
            path: RELATIVE_PATH,
            contextValue: "subversionr.changedFile.baseDiffable",
            kind: "file",
            generation: 11,
          },
        ],
      },
    ],
  };
}

function coverageRecord(
  overrides: Partial<Pick<CompletedStatusRefreshCoverage, "generation">> = {},
): CompletedStatusRefreshCoverage {
  return {
    repositoryId: "repo-uuid:C:/fixture/wc",
    epoch: 7,
    generation: overrides.generation ?? 11,
    targets: [{ path: RELATIVE_PATH, depth: "empty", reason: "fileChanged" }],
    coverage: [{ path: RELATIVE_PATH, depth: "empty", generation: overrides.generation ?? 11, reason: "fileChanged" }],
    completeness: "partial",
    timestamp: "2026-07-19T00:00:00Z",
    source: "libsvn-local",
  };
}

function watcherEvent(): AcceptedRepositoryWatcherEvent {
  return {
    repositoryId: "repo-uuid:C:/fixture/wc",
    epoch: 7,
    absolutePath: `C:/fixture/wc/${RELATIVE_PATH}`,
    kind: "changed",
    timestamp: 100,
  };
}

function candidateDiagnostics(): Record<string, unknown> {
  return {
    source: "subversionr-daemon",
    protocol: { major: 1, minor: 35 },
    capabilities: { remoteSvnAnonymous: true },
  };
}

function emitSuccessfulCausalInputs(harness: ObserverHarness): void {
  harness.counters.statusRefreshRequestCount += 1;
  harness.watcherEvents.emit(watcherEvent());
  harness.coverage.emit(coverageRecord());
}

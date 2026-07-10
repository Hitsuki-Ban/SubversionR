import { describe, expect, it, vi } from "vitest";
import {
  InstalledSourceControlUiE2eStatusRefreshProbe,
  InstalledSourceControlUiE2eStatusRefreshProbeError,
} from "../src/diagnostics/installedSourceControlUiE2eStatusRefreshProbe";
import type { StatusRefreshClient, StatusRefreshRequest } from "../src/status/types";

describe("InstalledSourceControlUiE2eStatusRefreshProbe", () => {
  it("holds the next matching manual full reconcile until the caller cancellation signal aborts", async () => {
    const inner = fakeStatusRefreshClient();
    const clearTimeoutSpy = vi.fn((timer: ReturnType<typeof setTimeout>) => clearTimeout(timer));
    const probe = new InstalledSourceControlUiE2eStatusRefreshProbe(inner, {
      generatedAt: sequenceNow(["2026-06-26T00:00:00.000Z", "2026-06-26T00:00:01.000Z"]),
      setTimeout: deferredTimeout,
      clearTimeout: clearTimeoutSpy,
    });
    const cancellation = new AbortController();
    const armed = probe.armNextManualFullReconcile({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      timeoutMs: 30000,
    });

    const refresh = probe.refreshStatus(manualFullReconcileRequest(), { signal: cancellation.signal });
    await flushMicrotasks();
    cancellation.abort();

    await expect(refresh).rejects.toThrow("SUBVERSIONR_INSTALLED_UI_E2E_MANUAL_FULL_RECONCILE_CANCELLED");
    expect(inner.refreshStatus).not.toHaveBeenCalled();
    expect(probe.report({ holdId: armed.holdId })).toEqual({
      kind: "subversionr.installedSourceControlUiE2eFullReconcileCancellationReport",
      generatedAt: "2026-06-26T00:00:01.000Z",
      holdId: armed.holdId,
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      target: { path: ".", depth: "infinity", reason: "manualFullReconcile" },
      observed: true,
      cancellationObserved: true,
      refreshStatusSignalProvided: true,
      signalAborted: true,
      assertions: {
        matchedManualFullReconcile: true,
        signalProvided: true,
        signalAborted: true,
        cancellationObserved: true,
      },
    });
  });

  it("passes nonmatching status refresh requests through to the wrapped client", async () => {
    const inner = fakeStatusRefreshClient();
    const probe = new InstalledSourceControlUiE2eStatusRefreshProbe(inner);
    probe.armNextManualFullReconcile({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      timeoutMs: 30000,
    });

    await probe.refreshStatus({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
    });

    expect(inner.refreshStatus).toHaveBeenCalledTimes(1);
  });

  it("reports an observed dirty-generation refresh before completing it on scheduler cancellation", async () => {
    const inner = fakeStatusRefreshClient();
    const clearTimeoutSpy = vi.fn((timer: ReturnType<typeof setTimeout>) => clearTimeout(timer));
    const probe = new InstalledSourceControlUiE2eStatusRefreshProbe(inner, {
      generatedAt: sequenceNow([
        "2026-06-26T00:00:00.000Z",
        "2026-06-26T00:00:01.000Z",
        "2026-06-26T00:00:02.000Z",
      ]),
      setTimeout: deferredTimeout,
      clearTimeout: clearTimeoutSpy,
    });
    const cancellation = new AbortController();
    const armed = probe.armNextDirtyGenerationCancellation({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      timeoutMs: 30000,
      target: { path: "load/modified-002.txt", depth: "empty", reason: "fileChanged" },
    });

    const refresh = probe.refreshStatus({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "load/modified-002.txt", depth: "empty", reason: "fileChanged" }],
    }, { signal: cancellation.signal });
    await flushMicrotasks();

    expect(probe.dirtyGenerationCancellationReport({ holdId: armed.holdId })).toEqual({
      kind: "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationReport",
      generatedAt: "2026-06-26T00:00:01.000Z",
      holdId: armed.holdId,
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      target: { path: "load/modified-002.txt", depth: "empty", reason: "fileChanged" },
      observed: true,
      cancellationObserved: false,
      refreshStatusSignalProvided: true,
      signalAborted: false,
      assertions: {
        matchedDirtyGenerationTarget: true,
        signalProvided: true,
        signalAborted: false,
        cancellationObserved: false,
      },
    });

    cancellation.abort();

    await expect(refresh).rejects.toThrow("SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_GENERATION_CANCELLED");
    expect(inner.refreshStatus).not.toHaveBeenCalled();
    expect(probe.dirtyGenerationCancellationReport({ holdId: armed.holdId })).toEqual({
      kind: "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationReport",
      generatedAt: "2026-06-26T00:00:02.000Z",
      holdId: armed.holdId,
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      target: { path: "load/modified-002.txt", depth: "empty", reason: "fileChanged" },
      observed: true,
      cancellationObserved: true,
      refreshStatusSignalProvided: true,
      signalAborted: true,
      assertions: {
        matchedDirtyGenerationTarget: true,
        signalProvided: true,
        signalAborted: true,
        cancellationObserved: true,
      },
    });
  });

  it("fails fast when a second hold is armed before the first one is consumed", () => {
    const probe = new InstalledSourceControlUiE2eStatusRefreshProbe(fakeStatusRefreshClient());
    probe.armNextManualFullReconcile({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      timeoutMs: 30000,
    });

    expect(() =>
      probe.armNextManualFullReconcile({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        timeoutMs: 30000,
      }),
    ).toThrow(InstalledSourceControlUiE2eStatusRefreshProbeError);
  });
});

function manualFullReconcileRequest(): StatusRefreshRequest {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    targets: [{ path: ".", depth: "infinity", reason: "manualFullReconcile" }],
  };
}

function fakeStatusRefreshClient(): StatusRefreshClient & {
  refreshStatus: ReturnType<typeof vi.fn<StatusRefreshClient["refreshStatus"]>>;
} {
  return {
    refreshStatus: vi.fn<StatusRefreshClient["refreshStatus"]>().mockResolvedValue({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      generation: 8,
      completeness: "complete",
      coverage: [{ path: ".", depth: "infinity", generation: 8, reason: "manualFullReconcile" }],
      upsert: [],
      remove: [],
      remoteUpsert: [],
      remoteRemove: [],
      summaryDelta: {
        localChanges: 0,
        remoteChanges: 0,
        conflicts: 0,
        unversioned: 0,
      },
      timestamp: "2026-06-26T00:00:00.000Z",
      source: "test",
    }),
  };
}

function sequenceNow(values: string[]): () => string {
  let index = 0;
  return () => values[Math.min(index++, values.length - 1)] ?? values[values.length - 1]!;
}

function deferredTimeout(callback: () => void): ReturnType<typeof setTimeout> {
  return setTimeout(callback, 60_000);
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

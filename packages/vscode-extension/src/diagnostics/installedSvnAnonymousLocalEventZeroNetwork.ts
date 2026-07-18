import * as nodePath from "node:path";
import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import type {
  VscodeSourceControlPresenter,
  VscodeSourceControlSnapshot,
} from "../scm/vscodeSourceControlPresenter";
import type {
  AcceptedRepositoryWatcherEvent,
  DisposableLike,
  RepositoryWatcherService,
} from "../status/repositoryWatcherService";
import type { StatusRefreshCoverageStore } from "../status/statusRefreshCoverageStore";
import type { CompletedStatusRefreshCoverage } from "../status/statusRefreshScheduler";
import type { PathCasePolicy, RawWatcherEventKind, StatusRefreshTarget } from "../status/types";
import type { InstalledSvnAnonymousAuthActivity } from "./installedSvnAnonymousReport";

const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-svn-anonymous-local-event-zero-network.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousLocalEventZeroNetwork";
const REPORT_CELL = "localEventZeroNetwork";
const REPORT_SURFACE = "installed";
const MAX_TIMEOUT_MS = 300_000;
const MAX_RELATIVE_PATH_LENGTH = 4_096;
const MAX_REPORT_BYTES = 8_192;
const MAX_DIAGNOSTICS_BYTES = 32_768;
const CHANGED_FILE_CONTEXT_VALUE = "subversionr.changedFile.baseDiffable";

export interface InstalledSvnAnonymousLocalEventZeroNetworkCounters {
  statusRefreshRequestCount: number;
  remoteStatusRequestCount: number;
  reconcileRequestCount: number;
}

export interface InstalledSvnAnonymousLocalEventZeroNetworkOptions {
  expectedToken: string | undefined;
  workspaceTrusted(): boolean;
  pathCase: PathCasePolicy;
  sessionService: Pick<RepositorySessionService, "openWorkingCopy" | "closeRepository">;
  watcherService: Pick<RepositoryWatcherService, "onDidAcceptWatcherEvent">;
  statusRefreshCoverage: Pick<StatusRefreshCoverageStore, "onDidRecordCompletedStatusRefreshCoverage">;
  sourceControlSurface: Pick<VscodeSourceControlPresenter, "snapshotRepository">;
  counters(): InstalledSvnAnonymousLocalEventZeroNetworkCounters;
  authActivity(): InstalledSvnAnonymousAuthActivity;
  collectDiagnostics(): Promise<unknown>;
  runtime?: Partial<InstalledSvnAnonymousLocalEventZeroNetworkRuntime>;
}

export interface InstalledSvnAnonymousLocalEventZeroNetworkArmReport {
  schema: typeof REPORT_SCHEMA;
  schemaVersion: 1;
  kind: typeof REPORT_KIND;
  status: "armed";
  cell: typeof REPORT_CELL;
  surface: typeof REPORT_SURFACE;
  observationId: string;
  target: StatusRefreshTarget;
}

export interface InstalledSvnAnonymousLocalEventZeroNetworkReport {
  schema: typeof REPORT_SCHEMA;
  schemaVersion: 1;
  kind: typeof REPORT_KIND;
  status: "passed";
  cell: typeof REPORT_CELL;
  surface: typeof REPORT_SURFACE;
  watcherObserved: true;
  watcherEventKinds: RawWatcherEventKind[];
  target: StatusRefreshTarget;
  projectionObserved: true;
  statusRefreshRequestDelta: number;
  remoteStatusRequestDelta: 0;
  reconcileRequestDelta: 0;
  authActivity: InstalledSvnAnonymousAuthActivity;
  diagnosticsRedacted: true;
}

interface InstalledSvnAnonymousLocalEventZeroNetworkRuntime {
  now(): number;
  setTimeout(callback: () => void, ms: number): ReturnType<typeof setTimeout>;
  clearTimeout(timer: ReturnType<typeof setTimeout>): void;
}

interface ArmRequest {
  token: string;
  workingCopyPath: string;
  relativePath: string;
  timeoutMs: number;
}

interface ActiveObservation {
  observationId: string;
  token: string;
  repositoryId: string;
  epoch: number;
  workingCopyPath: string;
  relativePath: string;
  targetAbsolutePathKey: string;
  pathCase: PathCasePolicy;
  deadlineMs: number;
  baseline: InstalledSvnAnonymousLocalEventZeroNetworkCounters;
  authBaseline: InstalledSvnAnonymousAuthActivity;
  watcherObserved: boolean;
  watcherEventKinds: Set<RawWatcherEventKind>;
  coverageGeneration: number | undefined;
  completionStarted: boolean;
  watcherSubscription: DisposableLike;
  coverageSubscription: DisposableLike;
  deadlineTimer: ReturnType<typeof setTimeout>;
}

type TerminalObservation =
  | { kind: "report"; observationId: string; report: InstalledSvnAnonymousLocalEventZeroNetworkReport }
  | { kind: "error"; observationId: string; error: InstalledSvnAnonymousLocalEventZeroNetworkError };

interface Awaiter {
  resolve(report: InstalledSvnAnonymousLocalEventZeroNetworkReport): void;
  reject(error: InstalledSvnAnonymousLocalEventZeroNetworkError): void;
}

export class InstalledSvnAnonymousLocalEventZeroNetworkObserver implements DisposableLike {
  private readonly runtime: InstalledSvnAnonymousLocalEventZeroNetworkRuntime;
  private active: ActiveObservation | undefined;
  private terminal: TerminalObservation | undefined;
  private awaiter: Awaiter | undefined;
  private settlingObservationId: string | undefined;
  private arming = false;
  private disposed = false;
  private observationSequence = 0;

  public constructor(private readonly options: InstalledSvnAnonymousLocalEventZeroNetworkOptions) {
    this.runtime = {
      now: options.runtime?.now ?? Date.now,
      setTimeout: options.runtime?.setTimeout ?? ((callback, ms) => setTimeout(callback, ms)),
      clearTimeout: options.runtime?.clearTimeout ?? ((timer) => clearTimeout(timer)),
    };
  }

  public async arm(rawRequest: unknown): Promise<InstalledSvnAnonymousLocalEventZeroNetworkArmReport> {
    this.requireIdle();
    const request = parseArmRequest(rawRequest, this.options.expectedToken);
    if (!this.options.workspaceTrusted()) {
      throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_WORKSPACE_UNTRUSTED", "lifecycle");
    }
    this.arming = true;
    let session: RepositorySession;
    try {
      session = await this.options.sessionService.openWorkingCopy({
        path: request.workingCopyPath,
        pathCase: this.options.pathCase,
      });
    } catch (error) {
      this.arming = false;
      throw error;
    }
    let watcherSubscription: DisposableLike | undefined;
    let coverageSubscription: DisposableLike | undefined;
    try {
      if (this.disposed) {
        throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DISPOSED", "lifecycle");
      }
      requireOpenedSession(session, request.workingCopyPath, this.options.pathCase);
      const baseline = requireCounters(this.options.counters());
      const authBaseline = requireAuthActivity(this.options.authActivity());
      const deadlineMs = this.runtime.now() + request.timeoutMs;
      if (!Number.isSafeInteger(deadlineMs)) {
        throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DEADLINE_INVALID", "input");
      }
      const targetAbsolutePathKey = absolutePathKey(
        session.watchScope.pathCase,
        resolveRepositoryRelativePath(request.workingCopyPath, request.relativePath),
      );
      const observationId = `local-event-zero-network-${++this.observationSequence}`;
      watcherSubscription = this.options.watcherService.onDidAcceptWatcherEvent((event) => {
        this.recordWatcherEvent(event);
      });
      coverageSubscription = this.options.statusRefreshCoverage.onDidRecordCompletedStatusRefreshCoverage((record) => {
        this.recordCompletedCoverage(record);
      });
      const deadlineTimer = this.runtime.setTimeout(() => {
        this.expireAtDeadline();
      }, request.timeoutMs);
      this.active = {
        observationId,
        token: request.token,
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        workingCopyPath: request.workingCopyPath,
        relativePath: request.relativePath,
        targetAbsolutePathKey,
        pathCase: session.watchScope.pathCase,
        deadlineMs,
        baseline,
        authBaseline,
        watcherObserved: false,
        watcherEventKinds: new Set(),
        coverageGeneration: undefined,
        completionStarted: false,
        watcherSubscription,
        coverageSubscription,
        deadlineTimer,
      };
      this.arming = false;
      return armReport(observationId, request.relativePath);
    } catch (error) {
      coverageSubscription?.dispose();
      watcherSubscription?.dispose();
      try {
        await this.options.sessionService.closeRepository(session.repositoryId);
      } catch {
        this.arming = false;
        throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_CLOSE_FAILED", "lifecycle");
      }
      this.arming = false;
      throw error;
    }
  }

  public async awaitReport(rawRequest: unknown): Promise<InstalledSvnAnonymousLocalEventZeroNetworkReport> {
    const observationId = parseAwaitRequest(rawRequest, this.options.expectedToken);
    if (this.awaiter) {
      throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_AWAIT_ALREADY_PENDING", "lifecycle");
    }
    const terminal = this.consumeTerminal(observationId);
    if (terminal) {
      return terminal;
    }
    const active = this.active;
    if (!active && this.settlingObservationId !== observationId) {
      throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REPORT_MISSING", "lifecycle");
    }
    if (active && active.observationId !== observationId) {
      throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_OBSERVATION_MISMATCH", "input");
    }
    const report = new Promise<InstalledSvnAnonymousLocalEventZeroNetworkReport>((resolve, reject) => {
      this.awaiter = { resolve, reject };
    });
    if (active && this.runtime.now() >= active.deadlineMs) {
      this.expireAtDeadline();
    }
    return await report;
  }

  public dispose(): void {
    this.disposed = true;
    const active = this.active;
    if (!active) {
      return;
    }
    void this.finishWithError(
      observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DISPOSED", "lifecycle"),
    );
  }

  private requireIdle(): void {
    if (this.disposed) {
      throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DISPOSED", "lifecycle");
    }
    if (this.active || this.terminal || this.awaiter || this.settlingObservationId || this.arming) {
      throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_ALREADY_ARMED", "lifecycle");
    }
  }

  private recordWatcherEvent(event: AcceptedRepositoryWatcherEvent): void {
    const active = this.active;
    if (!active || this.expireIfDeadlineReached(active)) {
      return;
    }
    if (
      event.repositoryId !== active.repositoryId ||
      event.epoch !== active.epoch ||
      absolutePathKey(active.pathCase, event.absolutePath) !== active.targetAbsolutePathKey
    ) {
      return;
    }
    active.watcherObserved = true;
    active.watcherEventKinds.add(event.kind);
    this.tryComplete(active);
  }

  private recordCompletedCoverage(record: CompletedStatusRefreshCoverage): void {
    const active = this.active;
    if (!active || this.expireIfDeadlineReached(active)) {
      return;
    }
    if (record.repositoryId !== active.repositoryId || record.epoch !== active.epoch || !active.watcherObserved) {
      return;
    }
    const hasExpectedTarget = record.targets.some((target) => isExpectedTarget(target, active.relativePath));
    if (!hasExpectedTarget) {
      return;
    }
    const hasExpectedCoverage = record.coverage.some(
      (scope) =>
        scope.path === active.relativePath &&
        scope.depth === "empty" &&
        scope.reason === "fileChanged" &&
        scope.generation === record.generation,
    );
    if (record.source !== "libsvn-local" || !hasExpectedCoverage || !Number.isSafeInteger(record.generation)) {
      void this.finishWithError(
        observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_COVERAGE_INVALID", "lifecycle"),
      );
      return;
    }
    active.coverageGeneration = record.generation;
    this.tryComplete(active);
  }

  private tryComplete(active: ActiveObservation): void {
    if (
      this.active !== active ||
      !active.watcherObserved ||
      active.coverageGeneration === undefined ||
      active.completionStarted
    ) {
      return;
    }
    active.completionStarted = true;
    void this.complete(active);
  }

  private async complete(active: ActiveObservation): Promise<void> {
    const coverageGeneration = active.coverageGeneration;
    if (coverageGeneration === undefined) {
      void this.finishWithError(
        observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_COVERAGE_INVALID", "lifecycle"),
      );
      return;
    }
    const snapshot = this.options.sourceControlSurface.snapshotRepository(active.repositoryId);
    if (!isChangedFileProjection(snapshot, active, coverageGeneration)) {
      void this.finishWithError(
        observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_PROJECTION_INVALID", "lifecycle"),
      );
      return;
    }
    let current: InstalledSvnAnonymousLocalEventZeroNetworkCounters;
    try {
      current = requireCounters(this.options.counters());
    } catch {
      void this.finishWithError(
        observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_COUNTER_INVALID", "lifecycle"),
      );
      return;
    }
    const statusRefreshRequestDelta = current.statusRefreshRequestCount - active.baseline.statusRefreshRequestCount;
    const remoteStatusRequestDelta = current.remoteStatusRequestCount - active.baseline.remoteStatusRequestCount;
    const reconcileRequestDelta = current.reconcileRequestCount - active.baseline.reconcileRequestCount;
    if (
      !Number.isSafeInteger(statusRefreshRequestDelta) ||
      statusRefreshRequestDelta < 1 ||
      remoteStatusRequestDelta !== 0 ||
      reconcileRequestDelta !== 0
    ) {
      void this.finishWithError(
        observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_ACTIVITY_INVALID", "lifecycle"),
      );
      return;
    }
    let authActivity: InstalledSvnAnonymousAuthActivity;
    try {
      authActivity = subtractAuthActivity(requireAuthActivity(this.options.authActivity()), active.authBaseline);
    } catch {
      void this.finishWithError(
        observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_AUTH_ACTIVITY_INVALID", "lifecycle"),
      );
      return;
    }
    if (
      authActivity.credentialRequests !== 0 ||
      authActivity.credentialSettlements !== 0 ||
      authActivity.certificateRequests !== 0
    ) {
      void this.finishWithError(
        observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_AUTH_ACTIVITY_INVALID", "lifecycle"),
      );
      return;
    }
    let diagnostics: unknown;
    try {
      diagnostics = await this.options.collectDiagnostics();
    } catch {
      if (this.active === active) {
        void this.finishWithError(
          observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DIAGNOSTICS_INVALID", "lifecycle"),
        );
      }
      return;
    }
    if (this.active !== active || this.expireIfDeadlineReached(active)) {
      return;
    }
    try {
      requireRedactedDiagnostics(diagnostics, active);
    } catch {
      void this.finishWithError(
        observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DIAGNOSTICS_INVALID", "lifecycle"),
      );
      return;
    }
    const report: InstalledSvnAnonymousLocalEventZeroNetworkReport = {
      schema: REPORT_SCHEMA,
      schemaVersion: 1,
      kind: REPORT_KIND,
      status: "passed",
      cell: REPORT_CELL,
      surface: REPORT_SURFACE,
      watcherObserved: true,
      watcherEventKinds: Array.from(active.watcherEventKinds).sort(),
      target: expectedTarget(active.relativePath),
      projectionObserved: true,
      statusRefreshRequestDelta,
      remoteStatusRequestDelta: 0,
      reconcileRequestDelta: 0,
      authActivity,
      diagnosticsRedacted: true,
    };
    try {
      requireBoundedRedactedReport(report, active);
    } catch {
      void this.finishWithError(
        observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REPORT_REDACTION_INVALID", "lifecycle"),
      );
      return;
    }
    void this.finishWithReport(report);
  }

  private expireIfDeadlineReached(active: ActiveObservation): boolean {
    if (this.runtime.now() < active.deadlineMs) {
      return false;
    }
    this.expireAtDeadline();
    return true;
  }

  private expireAtDeadline(): void {
    if (!this.active) {
      return;
    }
    void this.finishWithError(
      observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_TIMEOUT", "timeout"),
    );
  }

  private async finishWithReport(report: InstalledSvnAnonymousLocalEventZeroNetworkReport): Promise<void> {
    const active = this.detachActive();
    if (!active) {
      return;
    }
    const closeError = await this.closeSession(active.repositoryId);
    if (closeError) {
      this.deliverError(active.observationId, closeError);
      return;
    }
    this.deliverReport(active.observationId, report);
  }

  private async finishWithError(error: InstalledSvnAnonymousLocalEventZeroNetworkError): Promise<void> {
    const active = this.detachActive();
    if (!active) {
      return;
    }
    const closeError = await this.closeSession(active.repositoryId);
    this.deliverError(active.observationId, closeError ?? error);
  }

  private deliverReport(
    observationId: string,
    report: InstalledSvnAnonymousLocalEventZeroNetworkReport,
  ): void {
    this.settlingObservationId = undefined;
    const awaiter = this.awaiter;
    this.awaiter = undefined;
    if (awaiter) {
      awaiter.resolve(report);
      return;
    }
    this.terminal = { kind: "report", observationId, report };
  }

  private deliverError(observationId: string, error: InstalledSvnAnonymousLocalEventZeroNetworkError): void {
    this.settlingObservationId = undefined;
    const awaiter = this.awaiter;
    this.awaiter = undefined;
    if (awaiter) {
      awaiter.reject(error);
      return;
    }
    this.terminal = { kind: "error", observationId, error };
  }

  private detachActive(): ActiveObservation | undefined {
    const active = this.active;
    if (!active) {
      return undefined;
    }
    this.active = undefined;
    this.settlingObservationId = active.observationId;
    this.runtime.clearTimeout(active.deadlineTimer);
    active.coverageSubscription.dispose();
    active.watcherSubscription.dispose();
    return active;
  }

  private async closeSession(repositoryId: string): Promise<InstalledSvnAnonymousLocalEventZeroNetworkError | undefined> {
    try {
      await this.options.sessionService.closeRepository(repositoryId);
      return undefined;
    } catch {
      return observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_CLOSE_FAILED", "lifecycle");
    }
  }

  private consumeTerminal(observationId: string): InstalledSvnAnonymousLocalEventZeroNetworkReport | undefined {
    const terminal = this.terminal;
    if (!terminal) {
      return undefined;
    }
    if (terminal.observationId !== observationId) {
      throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_OBSERVATION_MISMATCH", "input");
    }
    this.terminal = undefined;
    if (terminal.kind === "error") {
      throw terminal.error;
    }
    return terminal.report;
  }

}

function parseArmRequest(value: unknown, expectedToken: string | undefined): ArmRequest {
  requireExpectedToken(value, expectedToken);
  const request = value as Record<string, unknown>;
  requireExactKeys(request, ["token", "workingCopyPath", "relativePath", "timeoutMs"]);
  if (
    typeof request.workingCopyPath !== "string" ||
    request.workingCopyPath.length === 0 ||
    !isAbsolutePath(request.workingCopyPath) ||
    /[\0\r\n]/u.test(request.workingCopyPath) ||
    typeof request.relativePath !== "string" ||
    !isSafeRepositoryRelativePath(request.relativePath) ||
    request.relativePath.length > MAX_RELATIVE_PATH_LENGTH ||
    typeof request.timeoutMs !== "number" ||
    !Number.isSafeInteger(request.timeoutMs) ||
    request.timeoutMs < 1 ||
    request.timeoutMs > MAX_TIMEOUT_MS
  ) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID", "input");
  }
  return {
    token: request.token as string,
    workingCopyPath: request.workingCopyPath,
    relativePath: request.relativePath,
    timeoutMs: request.timeoutMs,
  };
}

function parseAwaitRequest(value: unknown, expectedToken: string | undefined): string {
  requireExpectedToken(value, expectedToken);
  const request = value as Record<string, unknown>;
  requireExactKeys(request, ["token", "observationId"]);
  if (
    typeof request.observationId !== "string" ||
    !/^local-event-zero-network-[1-9][0-9]*$/u.test(request.observationId)
  ) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID", "input");
  }
  return request.observationId;
}

function requireExpectedToken(value: unknown, expectedToken: string | undefined): void {
  if (
    typeof expectedToken !== "string" ||
    expectedToken.length === 0 ||
    !isRecord(value) ||
    value.token !== expectedToken
  ) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_FORBIDDEN", "input");
  }
}

function requireExactKeys(value: Record<string, unknown>, keys: readonly string[]): void {
  if (Object.keys(value).sort().join(",") !== [...keys].sort().join(",")) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID", "input");
  }
}

function requireOpenedSession(
  session: RepositorySession,
  workingCopyPath: string,
  pathCase: PathCasePolicy,
): void {
  const requested = absolutePathKey(pathCase, workingCopyPath);
  if (
    !isRecord(session) ||
    typeof session.repositoryId !== "string" ||
    session.repositoryId.length === 0 ||
    !Number.isSafeInteger(session.epoch) ||
    session.epoch < 1 ||
    !isRecord(session.identity) ||
    typeof session.identity.workingCopyRoot !== "string" ||
    absolutePathKey(pathCase, session.identity.workingCopyRoot) !== requested ||
    !isRecord(session.watchScope) ||
    session.watchScope.repositoryId !== session.repositoryId ||
    session.watchScope.epoch !== session.epoch ||
    session.watchScope.pathCase !== pathCase ||
    typeof session.watchScope.workingCopyRoot !== "string" ||
    absolutePathKey(pathCase, session.watchScope.workingCopyRoot) !== requested
  ) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_SESSION_INVALID", "lifecycle");
  }
}

function requireCounters(
  value: InstalledSvnAnonymousLocalEventZeroNetworkCounters,
): InstalledSvnAnonymousLocalEventZeroNetworkCounters {
  if (
    !isRecord(value) ||
    !Number.isSafeInteger(value.statusRefreshRequestCount) ||
    value.statusRefreshRequestCount < 0 ||
    !Number.isSafeInteger(value.remoteStatusRequestCount) ||
    value.remoteStatusRequestCount < 0 ||
    !Number.isSafeInteger(value.reconcileRequestCount) ||
    value.reconcileRequestCount < 0
  ) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_COUNTER_INVALID", "lifecycle");
  }
  return { ...value };
}

function requireAuthActivity(value: InstalledSvnAnonymousAuthActivity): InstalledSvnAnonymousAuthActivity {
  if (
    !isRecord(value) ||
    !Number.isSafeInteger(value.credentialRequests) ||
    value.credentialRequests < 0 ||
    !Number.isSafeInteger(value.credentialSettlements) ||
    value.credentialSettlements < 0 ||
    !Number.isSafeInteger(value.certificateRequests) ||
    value.certificateRequests < 0
  ) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_AUTH_ACTIVITY_INVALID", "lifecycle");
  }
  return { ...value };
}

function subtractAuthActivity(
  after: InstalledSvnAnonymousAuthActivity,
  before: InstalledSvnAnonymousAuthActivity,
): InstalledSvnAnonymousAuthActivity {
  return requireAuthActivity({
    credentialRequests: after.credentialRequests - before.credentialRequests,
    credentialSettlements: after.credentialSettlements - before.credentialSettlements,
    certificateRequests: after.certificateRequests - before.certificateRequests,
  });
}

function requireRedactedDiagnostics(value: unknown, active: ActiveObservation): void {
  if (
    !isRecord(value) ||
    value.source !== "subversionr-daemon" ||
    !isRecord(value.protocol) ||
    value.protocol.major !== 1 ||
    value.protocol.minor !== 35 ||
    !isRecord(value.capabilities) ||
    value.capabilities.remoteSvnAnonymous !== true
  ) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DIAGNOSTICS_INVALID", "lifecycle");
  }
  const serialized = JSON.stringify(value);
  const normalized = redactionComparisonText(serialized);
  const sensitive = [
    active.token,
    active.repositoryId,
    active.workingCopyPath,
    active.workingCopyPath.replaceAll("\\", "/"),
  ].map(redactionComparisonText);
  if (
    Buffer.byteLength(serialized, "utf8") > MAX_DIAGNOSTICS_BYTES ||
    sensitive.some((entry) => entry.length > 0 && normalized.includes(entry))
  ) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_DIAGNOSTICS_INVALID", "lifecycle");
  }
}

function isChangedFileProjection(
  snapshot: VscodeSourceControlSnapshot | undefined,
  active: ActiveObservation,
  coverageGeneration: number,
): boolean {
  if (
    !snapshot ||
    snapshot.repositoryId !== active.repositoryId ||
    snapshot.epoch !== active.epoch ||
    absolutePathKey(active.pathCase, snapshot.workingCopyRoot) !== absolutePathKey(active.pathCase, active.workingCopyPath) ||
    snapshot.generation !== coverageGeneration
  ) {
    return false;
  }
  const changes = snapshot.groups.find((group) => group.id === "changes");
  return changes?.resources.some(
    (resource) =>
      relativePathKey(active.pathCase, resource.path) === relativePathKey(active.pathCase, active.relativePath) &&
      resource.kind === "file" &&
      resource.contextValue === CHANGED_FILE_CONTEXT_VALUE &&
      resource.generation === snapshot.generation,
  ) === true;
}

function requireBoundedRedactedReport(
  report: InstalledSvnAnonymousLocalEventZeroNetworkReport,
  active: ActiveObservation,
): void {
  const serialized = JSON.stringify(report);
  const normalized = redactionComparisonText(serialized);
  const sensitive = [
    active.token,
    active.repositoryId,
    active.workingCopyPath,
    active.workingCopyPath.replaceAll("\\", "/"),
  ].map(redactionComparisonText);
  if (
    Buffer.byteLength(serialized, "utf8") > MAX_REPORT_BYTES ||
    sensitive.some((value) => value.length > 0 && normalized.includes(value))
  ) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REPORT_REDACTION_INVALID", "lifecycle");
  }
}

function armReport(observationId: string, relativePath: string): InstalledSvnAnonymousLocalEventZeroNetworkArmReport {
  return {
    schema: REPORT_SCHEMA,
    schemaVersion: 1,
    kind: REPORT_KIND,
    status: "armed",
    cell: REPORT_CELL,
    surface: REPORT_SURFACE,
    observationId,
    target: expectedTarget(relativePath),
  };
}

function expectedTarget(relativePath: string): StatusRefreshTarget {
  return { path: relativePath, depth: "empty", reason: "fileChanged" };
}

function isExpectedTarget(target: StatusRefreshTarget, relativePath: string): boolean {
  return target.path === relativePath && target.depth === "empty" && target.reason === "fileChanged";
}

function isSafeRepositoryRelativePath(value: string): boolean {
  if (
    value.length === 0 ||
    value.includes("\\") ||
    value.startsWith("/") ||
    value.endsWith("/") ||
    value.includes(":") ||
    /[\0\r\n]/u.test(value)
  ) {
    return false;
  }
  const segments = value.split("/");
  return segments.every(
    (segment) => segment.length > 0 && segment !== "." && segment !== ".." && segment.toLocaleLowerCase("en-US") !== ".svn",
  );
}

function resolveRepositoryRelativePath(root: string, relativePath: string): string {
  const pathApi = nodePath.win32.isAbsolute(root) ? nodePath.win32 : nodePath.posix;
  const resolved = pathApi.resolve(root, ...relativePath.split("/"));
  const rootKey = absolutePathKey("case-sensitive", root);
  const resolvedKey = absolutePathKey("case-sensitive", resolved);
  if (resolvedKey !== rootKey && !resolvedKey.startsWith(`${rootKey}/`)) {
    throw observerError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_REQUEST_INVALID", "input");
  }
  return resolved;
}

function absolutePathKey(pathCase: PathCasePolicy, value: string): string {
  const normalized = value.replaceAll("\\", "/").replace(/\/+$/u, "");
  return pathCase === "case-insensitive" ? normalized.toLocaleLowerCase("en-US") : normalized;
}

function relativePathKey(pathCase: PathCasePolicy, value: string): string {
  return pathCase === "case-insensitive" ? value.toLocaleLowerCase("en-US") : value;
}

function redactionComparisonText(value: string): string {
  return value
    .toLocaleLowerCase("en-US")
    .replaceAll("\\", "/")
    .replace(/\/+/gu, "/");
}

function isAbsolutePath(value: string): boolean {
  return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export class InstalledSvnAnonymousLocalEventZeroNetworkError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousLocalEventZeroNetworkInvalid";

  public constructor(
    public readonly code: string,
    public readonly category: "input" | "lifecycle" | "timeout",
  ) {
    super(code);
    this.name = "InstalledSvnAnonymousLocalEventZeroNetworkError";
  }
}

function observerError(
  code: string,
  category: "input" | "lifecycle" | "timeout",
): InstalledSvnAnonymousLocalEventZeroNetworkError {
  return new InstalledSvnAnonymousLocalEventZeroNetworkError(code, category);
}

import { createHash } from "node:crypto";
import {
  createCredentialController,
  CredentialRpcError,
  SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN,
  SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED,
  SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT,
  type CredentialController,
  type CredentialPromptUi,
  type CredentialRequest,
  type CredentialResponse,
  type CredentialSecretStorage,
  type CredentialSettlementOutcome,
} from "../auth/credentialController";

const LEGACY_INDEX_KEY = "subversionr.credential.index.v1";
const LEGACY_ENTRY_KEY = "subversionr.credential.v1.installed-evidence";

export interface InstalledCredentialLeaseReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  secretStorage: CredentialSecretStorage;
}

export async function collectInstalledCredentialLeaseReport(
  options: InstalledCredentialLeaseReportOptions,
): Promise<Record<string, unknown>> {
  if (
    typeof options.expectedToken !== "string" ||
    options.expectedToken.length === 0 ||
    requestToken(options.request) !== options.expectedToken
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_REPORT_FORBIDDEN");
  }

  const storage = new NamespacedSecretStorage(options.secretStorage, options.expectedToken);
  const ui = new EvidenceUi();
  let controller: CredentialController | undefined;
  try {
    await storage.store(LEGACY_INDEX_KEY, JSON.stringify({ version: 1, keys: [LEGACY_ENTRY_KEY] }));
    await storage.store(LEGACY_ENTRY_KEY, "legacy-evidence-secret");
    controller = evidenceController(storage, ui);

    const legacyBlocked = await controller.handleCredentialRequest(
      credentialRequest("01", "01", { interactive: false, origin: "background" }),
    );
    requireCancelCode(legacyBlocked, SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED);

    const initial = requireProvide(
      await controller.handleCredentialRequest(credentialRequest("02", "02")),
    );
    await settle(controller, initial, "accepted", "11");
    if (ui.legacyClearCount !== 1) {
      throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_LEGACY_CLEAR_INVALID");
    }

    const promptCountAfterInitial = ui.promptCount;
    const stored = requireProvide(
      await controller.handleCredentialRequest(
        credentialRequest("03", "03", { interactive: false, origin: "background" }),
      ),
    );
    await settle(controller, stored, "unused", "12");
    if (ui.promptCount !== promptCountAfterInitial) {
      throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_FIXED_REUSE_INVALID");
    }

    const bob = requireProvide(
      await controller.handleCredentialRequest(
        credentialRequest("04", "04", { account: { mode: "fixed", username: "bob" } }),
      ),
    );
    await settle(controller, bob, "accepted", "13");

    const chooser = requireProvide(
      await controller.handleCredentialRequest(
        credentialRequest("05", "05", { account: { mode: "chooseForeground" } }),
      ),
    );
    await settle(controller, chooser, "unused", "14");
    if (ui.chooserCount !== 1 || ui.lastChooserAccountCount !== 2) {
      throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_CHOOSER_INVALID");
    }

    const promptCountBeforeFlight = ui.promptCount;
    const [flightOne, flightTwo] = (
      await Promise.all([
        controller.handleCredentialRequest(
          credentialRequest("06", "06", { account: { mode: "fixed", username: "charlie" } }),
        ),
        controller.handleCredentialRequest(
          credentialRequest("07", "07", { account: { mode: "fixed", username: "charlie" } }),
        ),
      ])
    ).map(requireProvide);
    if (flightOne.leaseId === flightTwo.leaseId || ui.promptCount !== promptCountBeforeFlight + 1) {
      throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_SINGLE_FLIGHT_INVALID");
    }
    await settle(controller, flightOne, "cancelled", "15");
    await settle(controller, flightTwo, "timedOut", "16");

    const rejected = requireProvide(
      await controller.handleCredentialRequest(
        credentialRequest("08", "08", { account: { mode: "fixed", username: "bob" } }),
      ),
    );
    await settle(controller, rejected, "rejected", "17");
    const retry = requireProvide(
      await controller.handleCredentialRequest(
        credentialRequest("09", "08", {
          account: { mode: "fixed", username: "bob" },
          attempt: { kind: "retryAfterRejected", previousLeaseId: rejected.leaseId },
        }),
      ),
    );
    const accepted = await settle(controller, retry, "accepted", "18");
    const duplicate = await settle(controller, retry, "accepted", "18");
    if (JSON.stringify(accepted) !== JSON.stringify(duplicate)) {
      throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_IDEMPOTENCY_INVALID");
    }
    await requireCredentialError(
      () => settle(controller!, retry, "unused", "19"),
      SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT,
    );

    const pendingAcrossReload = requireProvide(
      await controller.handleCredentialRequest(
        credentialRequest("10", "10", { interactive: false, origin: "background" }),
      ),
    );
    controller.dispose();
    controller = evidenceController(storage, ui);
    await requireCredentialError(
      () => settle(controller!, pendingAcrossReload, "accepted", "20"),
      SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN,
    );

    const clearResult = await controller.clearSavedCredentials();
    controller.dispose();
    controller = undefined;
    await storage.cleanup();
    if (!(await storage.isClean())) {
      throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_CLEANUP_INVALID");
    }

    return {
      schemaVersion: 1,
      kind: "subversionr.installedCredentialLeaseReport",
      legacyBackgroundBlocked: true,
      legacyForegroundCleared: true,
      fixedStoredReuse: true,
      chooserMultiAccount: true,
      promptSingleFlight: true,
      independentLeases: true,
      settlementOutcomes: ["accepted", "rejected", "unused", "cancelled", "timedOut"],
      duplicateSettlementIdempotent: true,
      conflictingSettlementRejected: true,
      reloadDiscardedPendingLease: true,
      savedCredentialEntriesCleared: clearResult.deleted,
      storageCleanup: true,
    };
  } finally {
    controller?.dispose();
    await storage.cleanup();
  }
}

class EvidenceUi implements CredentialPromptUi {
  public legacyClearCount = 0;
  public promptCount = 0;
  public chooserCount = 0;
  public lastChooserAccountCount = 0;

  public async pickAccount(_request: CredentialRequest, accounts: readonly string[]): Promise<string | undefined> {
    this.chooserCount += 1;
    this.lastChooserAccountCount = accounts.length;
    return accounts.at(-1);
  }

  public async promptSecret(_request: CredentialRequest, _username: string): Promise<string | undefined> {
    this.promptCount += 1;
    await Promise.resolve();
    return "installed-evidence-secret";
  }

  public async pickPersistence(): Promise<"secretStorage"> {
    return "secretStorage";
  }

  public async confirmLegacyClear(): Promise<boolean> {
    this.legacyClearCount += 1;
    return true;
  }
}

class NamespacedSecretStorage implements CredentialSecretStorage {
  private readonly prefix: string;
  private readonly touched = new Set<string>();

  public constructor(
    private readonly storage: CredentialSecretStorage,
    token: string,
  ) {
    this.prefix = `subversionr.installed-evidence.${createHash("sha256").update(token).digest("hex")}.`;
  }

  public async get(key: string): Promise<string | undefined> {
    this.touched.add(key);
    return await this.storage.get(this.key(key));
  }

  public async store(key: string, value: string): Promise<void> {
    this.touched.add(key);
    await this.storage.store(this.key(key), value);
  }

  public async delete(key: string): Promise<void> {
    this.touched.add(key);
    await this.storage.delete(this.key(key));
  }

  public async cleanup(): Promise<void> {
    for (const key of this.touched) {
      await this.storage.delete(this.key(key));
    }
  }

  public async isClean(): Promise<boolean> {
    for (const key of this.touched) {
      if ((await this.storage.get(this.key(key))) !== undefined) {
        return false;
      }
    }
    return true;
  }

  private key(key: string): string {
    return `${this.prefix}${key}`;
  }
}

function evidenceController(storage: CredentialSecretStorage, ui: CredentialPromptUi): CredentialController {
  let sequence = 0x100;
  return createCredentialController({
    workspaceTrusted: () => true,
    secretStorage: storage,
    ui,
    createId: () => canonicalId((sequence++).toString(16)),
  });
}

function credentialRequest(
  requestSuffix: string,
  operationSuffix: string,
  overrides: Partial<CredentialRequest> = {},
): CredentialRequest {
  return {
    requestId: `installed-request-${requestSuffix}`,
    operationId: canonicalId(operationSuffix),
    endpoint: { scheme: "https", canonicalHost: "svn.example.invalid", effectivePort: 443 },
    authKind: "basic",
    realm: "SubversionR installed credential evidence",
    account: { mode: "fixed", username: "alice" },
    attempt: { kind: "initial" },
    interactive: true,
    persistenceAllowed: true,
    origin: "foreground",
    timeoutMs: 30_000,
    ...overrides,
  };
}

function canonicalId(suffix: string): string {
  return `00000000-0000-4000-8000-${suffix.padStart(12, "0")}`;
}

function requireProvide(response: CredentialResponse): Extract<CredentialResponse, { action: "provide" }> {
  if (response.action !== "provide") {
    throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_PROVIDE_INVALID");
  }
  return response;
}

function requireCancelCode(response: CredentialResponse, code: string): void {
  if (response.action !== "cancel" || response.error.code !== code) {
    throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_CANCEL_INVALID");
  }
}

async function settle(
  controller: CredentialController,
  response: Extract<CredentialResponse, { action: "provide" }>,
  outcome: CredentialSettlementOutcome,
  requestSuffix: string,
) {
  return await controller.handleCredentialSettlement({
    requestId: `installed-settlement-${requestSuffix}`,
    operationId: response.operationId,
    leaseId: response.leaseId,
    outcome,
    timeoutMs: 10_000,
  });
}

async function requireCredentialError(operation: () => Promise<unknown>, code: string): Promise<void> {
  try {
    await operation();
  } catch (error) {
    if (error instanceof CredentialRpcError && error.code === code) {
      return;
    }
    throw error;
  }
  throw reportError("SUBVERSIONR_INSTALLED_CREDENTIAL_ERROR_MISSING");
}

function requestToken(request: unknown): string | undefined {
  if (typeof request !== "object" || request === null || !("token" in request)) {
    return undefined;
  }
  const token = (request as { token?: unknown }).token;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

export class InstalledCredentialLeaseReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedCredentialLeaseReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledCredentialLeaseReportError";
  }
}

function reportError(code: string): InstalledCredentialLeaseReportError {
  return new InstalledCredentialLeaseReportError(code);
}

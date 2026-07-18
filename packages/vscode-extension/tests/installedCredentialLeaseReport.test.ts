import { describe, expect, it } from "vitest";
import {
  collectInstalledCredentialLeaseReport,
  InstalledCredentialLeaseReportError,
} from "../src/diagnostics/installedCredentialLeaseReport";
import type { CredentialSecretStorage } from "../src/auth/credentialController";

class MemorySecretStorage implements CredentialSecretStorage {
  public readonly values = new Map<string, string>();

  public async get(key: string): Promise<string | undefined> {
    return this.values.get(key);
  }

  public async store(key: string, value: string): Promise<void> {
    this.values.set(key, value);
  }

  public async delete(key: string): Promise<void> {
    this.values.delete(key);
  }
}

describe("installed credential lease report", () => {
  it("proves the installed controller matrix without leaking or retaining evidence secrets", async () => {
    const storage = new MemorySecretStorage();
    const report = await collectInstalledCredentialLeaseReport({
      expectedToken: "installed-token",
      request: { token: "installed-token" },
      secretStorage: storage,
    });

    expect(report).toMatchObject({
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
      storageCleanup: true,
    });
    expect(JSON.stringify(report)).not.toContain("alice");
    expect(JSON.stringify(report)).not.toContain("installed-evidence-secret");
    expect(storage.values.size).toBe(0);
  });

  it("fails closed when the harness token is absent or wrong", async () => {
    const storage = new MemorySecretStorage();
    await expect(
      collectInstalledCredentialLeaseReport({
        expectedToken: "installed-token",
        request: { token: "wrong" },
        secretStorage: storage,
      }),
    ).rejects.toEqual(
      new InstalledCredentialLeaseReportError("SUBVERSIONR_INSTALLED_CREDENTIAL_REPORT_FORBIDDEN"),
    );
    expect(storage.values.size).toBe(0);
  });
});

import { describe, expect, it, vi } from "vitest";
import type { CertificateTrustResponse } from "../src/auth/certificateTrustController";
import type {
  CredentialController,
  CredentialResponse,
  CredentialSettlementAck,
} from "../src/auth/credentialController";
import { createAuthRequestHandler } from "../src/auth/authRequestHandler";

function credentialController(overrides: Partial<CredentialController> = {}): CredentialController {
  return {
    handleCredentialRequest: vi.fn(),
    handleCredentialSettlement: vi.fn(),
    clearSavedCredentials: vi.fn(),
    discardOperation: vi.fn(),
    invalidateBackendConnection: vi.fn(),
    dispose: vi.fn(),
    ...overrides,
  };
}

describe("createAuthRequestHandler", () => {
  it("routes credentials/request to the credential controller", async () => {
    const response: CredentialResponse = {
      requestId: "cred-1",
      operationId: "00000000-0000-4000-8000-000000000001",
      action: "cancel",
      error: {
        code: "SUBVERSIONR_CREDENTIAL_CANCELLED",
        category: "auth",
        messageKey: "error.auth.credentialCancelled",
        args: {},
        retryable: false,
      },
    };
    const controller = credentialController({ handleCredentialRequest: vi.fn(async () => response) });
    const handler = createAuthRequestHandler({
      credentialController: controller,
      certificateTrustController: { handleCertificateTrustRequest: vi.fn() },
    });

    const params = {
      requestId: "cred-1",
      operationId: "00000000-0000-4000-8000-000000000001",
      endpoint: { scheme: "https", canonicalHost: "svn.example.com", effectivePort: 443 },
      authKind: "basic",
      realm: "Example Realm",
      account: { mode: "fixed", username: "alice" },
      attempt: { kind: "initial" },
      interactive: false,
      persistenceAllowed: true,
      origin: "background",
      timeoutMs: 30_000,
    };
    expect(await handler("credentials/request", params)).toBe(response);
    expect(controller.handleCredentialRequest).toHaveBeenCalledWith(params);
  });

  it("routes credentials/settle to the credential controller", async () => {
    const response: CredentialSettlementAck = {
      requestId: "settle-1",
      operationId: "00000000-0000-4000-8000-000000000001",
      leaseId: "00000000-0000-4000-8000-000000000002",
      outcome: "accepted",
    };
    const controller = credentialController({ handleCredentialSettlement: vi.fn(async () => response) });
    const handler = createAuthRequestHandler({
      credentialController: controller,
      certificateTrustController: { handleCertificateTrustRequest: vi.fn() },
    });

    const params = {
      requestId: "settle-1",
      operationId: "00000000-0000-4000-8000-000000000001",
      leaseId: "00000000-0000-4000-8000-000000000002",
      outcome: "accepted",
      timeoutMs: 30_000,
    };
    expect(await handler("credentials/settle", params)).toBe(response);
    expect(controller.handleCredentialSettlement).toHaveBeenCalledWith(params);
  });

  it("routes certificate/request to the certificate trust controller", async () => {
    const response: CertificateTrustResponse = {
      requestId: "cert-1",
      action: "trust",
      trust: "once",
      fingerprint: "AA:BB:CC",
      fingerprintAlgorithm: "sha256-der",
    };
    const handler = createAuthRequestHandler({
      credentialController: credentialController(),
      certificateTrustController: { handleCertificateTrustRequest: vi.fn(async () => response) },
    });

    expect(await handler("certificate/request", {
      requestId: "cert-1",
      realm: "https://svn.example.com:443",
      host: "svn.example.com",
      fingerprint: "AA:BB:CC",
      fingerprintAlgorithm: "sha256-der",
      failures: ["unknownCa"],
      validFrom: "2026-01-01T00:00:00Z",
      validTo: "2027-01-01T00:00:00Z",
      interactive: true,
      persistenceAllowed: true,
      origin: "foreground",
      timeoutMs: 30_000,
    })).toBe(response);
  });

  it("rejects unknown inbound auth methods with stable JSON-RPC errors", async () => {
    const handler = createAuthRequestHandler({
      credentialController: credentialController(),
      certificateTrustController: { handleCertificateTrustRequest: vi.fn() },
    });

    await expect(handler("auth/legacyCertificateRequest", {})).rejects.toMatchObject({
      code: "RPC_METHOD_NOT_FOUND",
      category: "unsupported",
      messageKey: "error.rpc.methodNotFound",
      safeArgs: { method: "auth/legacyCertificateRequest" },
      retryable: false,
    });
  });
});

import { describe, expect, it, vi } from "vitest";
import type { CertificateTrustResponse } from "../src/auth/certificateTrustController";
import type { CredentialResponse } from "../src/auth/credentialController";
import { createAuthRequestHandler } from "../src/auth/authRequestHandler";

describe("createAuthRequestHandler", () => {
  it("routes credentials/request to the credential controller", async () => {
    const credentialResponse: CredentialResponse = {
      requestId: "cred-1",
      action: "cancel",
      error: {
        code: "SUBVERSIONR_CREDENTIAL_CANCELLED",
        category: "auth",
        messageKey: "error.auth.credentialCancelled",
        args: {},
        retryable: false,
      },
    };
    const handler = createAuthRequestHandler({
      credentialController: {
        handleCredentialRequest: vi.fn(async () => credentialResponse),
        clearSavedCredentials: vi.fn(),
      },
      certificateTrustController: {
        handleCertificateTrustRequest: vi.fn(),
      },
    });

    const response = await handler("credentials/request", {
      requestId: "cred-1",
      realm: "svn://example",
      kind: "usernamePassword",
      interactive: false,
      persistenceAllowed: true,
      origin: "background",
      timeoutMs: 30000,
    });

    expect(response).toBe(credentialResponse);
  });

  it("routes certificate/request to the certificate trust controller", async () => {
    const certificateResponse: CertificateTrustResponse = {
      requestId: "cert-1",
      action: "trust",
      trust: "once",
      fingerprint: "AA:BB:CC",
      fingerprintAlgorithm: "sha256-der",
    };
    const handler = createAuthRequestHandler({
      credentialController: {
        handleCredentialRequest: vi.fn(),
        clearSavedCredentials: vi.fn(),
      },
      certificateTrustController: {
        handleCertificateTrustRequest: vi.fn(async () => certificateResponse),
      },
    });

    const response = await handler("certificate/request", {
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
      timeoutMs: 30000,
    });

    expect(response).toBe(certificateResponse);
  });

  it("rejects unknown inbound auth methods with stable JSON-RPC errors", async () => {
    const handler = createAuthRequestHandler({
      credentialController: {
        handleCredentialRequest: vi.fn(),
        clearSavedCredentials: vi.fn(),
      },
      certificateTrustController: {
        handleCertificateTrustRequest: vi.fn(),
      },
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

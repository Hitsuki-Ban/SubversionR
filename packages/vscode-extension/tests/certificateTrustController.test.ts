import { describe, expect, it, vi } from "vitest";
import {
  SUBVERSIONR_CERTIFICATE_CHANGED,
  SUBVERSIONR_CERTIFICATE_FINGERPRINT_ALGORITHM_UNSUPPORTED,
  SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE,
  SUBVERSIONR_CERTIFICATE_PERSISTENCE_DISALLOWED,
  SUBVERSIONR_CERTIFICATE_REJECTED,
  SUBVERSIONR_CERTIFICATE_TIMEOUT,
  SUBVERSIONR_CERTIFICATE_UNTRUSTED_WORKSPACE,
  type CertificateTrustRequest,
  createCertificateTrustController,
  createCertificateTrustRequestHandler,
} from "../src/auth/certificateTrustController";

describe("CertificateTrustController", () => {
  it("blocks untrusted workspaces before reading SecretStorage or prompting", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage, workspaceTrusted: false });

    const response = await controller.handleCertificateTrustRequest(request());

    expect(response).toMatchObject({
      requestId: "cert-1",
      action: "reject",
      error: {
        code: SUBVERSIONR_CERTIFICATE_UNTRUSTED_WORKSPACE,
        category: "lifecycle",
        messageKey: "error.auth.certificateUntrustedWorkspace",
      },
    });
    expect(secretStorage.get).not.toHaveBeenCalled();
    expect(controller.ui.pickTrust).not.toHaveBeenCalled();
  });

  it("rejects background requests with no stored trust and never prompts", async () => {
    const controller = createController();

    const response = await controller.handleCertificateTrustRequest(
      request({ interactive: false, origin: "background" }),
    );

    expect(response).toMatchObject({
      requestId: "cert-1",
      action: "reject",
      error: {
        code: SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE,
        category: "auth",
        messageKey: "error.auth.certificateNonInteractive",
        retryable: false,
      },
    });
    expect(response).toMatchObject({
      error: {
        args: {
          fingerprint: "AA:BB:CC",
          fingerprintAlgorithm: "sha256-der",
          origin: "background",
        },
      },
    });
    expect(JSON.stringify(response)).not.toContain("https://svn.example.com:443");
    expect(controller.ui.pickTrust).not.toHaveBeenCalled();
  });

  it("uses exact stored trust for non-interactive requests without prompting", async () => {
    const secretStorage = fakeSecretStorage();
    const ui = fakeUi({ decision: "permanent" });
    const controller = createController({ secretStorage, ui });

    await controller.handleCertificateTrustRequest(request());
    const response = await controller.handleCertificateTrustRequest(
      request({ requestId: "cert-2", interactive: false, origin: "background" }),
    );

    expect(response).toEqual({
      requestId: "cert-2",
      action: "trust",
      trust: "permanent",
      fingerprint: "AA:BB:CC",
      fingerprintAlgorithm: "sha256-der",
    });
    expect(ui.pickTrust).toHaveBeenCalledTimes(1);
  });

  it("rejects changed certificate fingerprints in background requests", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage, ui: fakeUi({ decision: "permanent" }) });
    await controller.handleCertificateTrustRequest(request());

    const response = await controller.handleCertificateTrustRequest(
      request({
        requestId: "cert-2",
        fingerprint: "DD:EE:FF",
        interactive: false,
        origin: "background",
      }),
    );

    expect(response).toMatchObject({
      requestId: "cert-2",
      action: "reject",
      error: {
        code: SUBVERSIONR_CERTIFICATE_CHANGED,
        category: "auth",
        messageKey: "error.auth.certificateChanged",
      },
    });
    expect(controller.ui.pickTrust).toHaveBeenCalledTimes(1);
  });

  it("prompts again for changed certificate fingerprints in foreground requests", async () => {
    const secretStorage = fakeSecretStorage();
    const ui = fakeUi({ decisions: ["permanent", "once"] });
    const controller = createController({ secretStorage, ui });
    await controller.handleCertificateTrustRequest(request());

    const response = await controller.handleCertificateTrustRequest(
      request({ requestId: "cert-2", fingerprint: "DD:EE:FF" }),
    );

    expect(response).toEqual({
      requestId: "cert-2",
      action: "trust",
      trust: "once",
      fingerprint: "DD:EE:FF",
      fingerprintAlgorithm: "sha256-der",
    });
    expect(ui.pickTrust).toHaveBeenCalledTimes(2);
  });

  it("trusts once without writing SecretStorage", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage, ui: fakeUi({ decision: "once" }) });

    const response = await controller.handleCertificateTrustRequest(request());

    expect(response).toEqual({
      requestId: "cert-1",
      action: "trust",
      trust: "once",
      fingerprint: "AA:BB:CC",
      fingerprintAlgorithm: "sha256-der",
    });
    expect(secretStorage.store).not.toHaveBeenCalled();
  });

  it("returns a distinct rejection code for explicit user rejection", async () => {
    const controller = createController({ ui: fakeUi({ decision: "reject" }) });

    const response = await controller.handleCertificateTrustRequest(request());

    expect(response).toMatchObject({
      requestId: "cert-1",
      action: "reject",
      error: {
        code: SUBVERSIONR_CERTIFICATE_REJECTED,
        category: "auth",
        messageKey: "error.auth.certificateRejected",
      },
    });
  });

  it("stores permanent trust without raw realm in the SecretStorage key", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage, ui: fakeUi({ decision: "permanent" }) });

    const response = await controller.handleCertificateTrustRequest(request());

    expect(response).toEqual({
      requestId: "cert-1",
      action: "trust",
      trust: "permanent",
      fingerprint: "AA:BB:CC",
      fingerprintAlgorithm: "sha256-der",
    });
    const [[key, value]] = secretStorage.store.mock.calls;
    expect(key).toMatch(/^subversionr\.certificateTrust\.v1\.[0-9a-f]{64}$/u);
    expect(key).not.toContain("svn.example.com");
    expect(JSON.parse(value)).toMatchObject({
      version: 1,
      fingerprint: "AA:BB:CC",
      fingerprintAlgorithm: "sha256-der",
    });
  });

  it("rejects permanent selection when persistence is not allowed", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage, ui: fakeUi({ decision: "permanent" }) });

    const response = await controller.handleCertificateTrustRequest(request({ persistenceAllowed: false }));

    expect(response).toMatchObject({
      action: "reject",
      error: {
        code: SUBVERSIONR_CERTIFICATE_PERSISTENCE_DISALLOWED,
        category: "auth",
        messageKey: "error.auth.certificatePersistenceDisallowed",
      },
    });
    expect(secretStorage.store).not.toHaveBeenCalled();
  });

  it("rejects unsupported certificate fingerprint algorithms without prompting", async () => {
    const controller = createController();

    const response = await controller.handleCertificateTrustRequest(
      request({ fingerprintAlgorithm: "sha1-libsvn" as "sha256-der" }),
    );

    expect(response).toMatchObject({
      requestId: "cert-1",
      action: "reject",
      error: {
        code: SUBVERSIONR_CERTIFICATE_FINGERPRINT_ALGORITHM_UNSUPPORTED,
        category: "auth",
        messageKey: "error.auth.certificateFingerprintAlgorithmUnsupported",
      },
    });
    expect(controller.ui.pickTrust).not.toHaveBeenCalled();
  });

  it("treats prompt timeout as certificate rejection", async () => {
    const ui = fakeUi();
    ui.pickTrust.mockImplementation(() => new Promise<"once" | "permanent" | "reject" | undefined>(() => undefined));
    const controller = createController({ ui });

    const response = await controller.handleCertificateTrustRequest(request({ timeoutMs: 1 }));

    expect(response).toMatchObject({
      requestId: "cert-1",
      action: "reject",
      error: {
        code: SUBVERSIONR_CERTIFICATE_TIMEOUT,
        category: "auth",
        messageKey: "error.auth.certificateTimeout",
      },
    });
  });

  it("coalesces concurrent prompts for the same realm and fingerprint while preserving request ids", async () => {
    const decision = deferred<"once" | "permanent" | "reject" | undefined>();
    const ui = fakeUi();
    ui.pickTrust.mockImplementation(async () => await decision.promise);
    const controller = createController({ ui });

    const first = controller.handleCertificateTrustRequest(request({ requestId: "cert-1" }));
    const second = controller.handleCertificateTrustRequest(request({ requestId: "cert-2" }));
    await flushMicrotasks();

    expect(ui.pickTrust).toHaveBeenCalledTimes(1);
    decision.resolve("once");

    await expect(Promise.all([first, second])).resolves.toEqual([
      {
        requestId: "cert-1",
        action: "trust",
        trust: "once",
        fingerprint: "AA:BB:CC",
        fingerprintAlgorithm: "sha256-der",
      },
      {
        requestId: "cert-2",
        action: "trust",
        trust: "once",
        fingerprint: "AA:BB:CC",
        fingerprintAlgorithm: "sha256-der",
      },
    ]);
  });

  it("routes JSON-RPC certificate/request payloads into the certificate trust controller", async () => {
    const controller = createController({ ui: fakeUi({ decision: "once" }) });
    const handler = createCertificateTrustRequestHandler(controller);

    const response = await handler("certificate/request", request());

    expect(response).toEqual({
      requestId: "cert-1",
      action: "trust",
      trust: "once",
      fingerprint: "AA:BB:CC",
      fingerprintAlgorithm: "sha256-der",
    });
  });
});

function createController(options: {
  workspaceTrusted?: boolean;
  secretStorage?: ReturnType<typeof fakeSecretStorage>;
  ui?: ReturnType<typeof fakeUi>;
} = {}) {
  const ui = options.ui ?? fakeUi();
  const controller = createCertificateTrustController({
    workspaceTrusted: () => options.workspaceTrusted ?? true,
    secretStorage: options.secretStorage ?? fakeSecretStorage(),
    ui,
    now: () => "2026-06-24T00:00:00.000Z",
  });
  return Object.assign(controller, { ui });
}

function request(overrides: Partial<CertificateTrustRequest> = {}): CertificateTrustRequest {
  return {
    requestId: "cert-1",
    realm: "https://svn.example.com:443",
    host: "svn.example.com",
    fingerprint: "AA:BB:CC",
    fingerprintAlgorithm: "sha256-der",
    failures: ["unknownCa", "hostnameMismatch"],
    validFrom: "2026-01-01T00:00:00Z",
    validTo: "2027-01-01T00:00:00Z",
    issuer: "CN=Example Test CA",
    subject: "CN=svn.example.com",
    interactive: true,
    persistenceAllowed: true,
    origin: "foreground",
    timeoutMs: 30000,
    repositoryId: "repo-uuid:C:/wc",
    workingCopyRoot: "C:/wc",
    ...overrides,
  };
}

function fakeUi(options: {
  decision?: "once" | "permanent" | "reject" | undefined;
  decisions?: Array<"once" | "permanent" | "reject" | undefined>;
} = {}) {
  const decisions = [...(options.decisions ?? [])];
  return {
    pickTrust: vi.fn<(_request: CertificateTrustRequest) => Promise<"once" | "permanent" | "reject" | undefined>>(
      async () => (decisions.length > 0 ? decisions.shift() : options.decision ?? "reject"),
    ),
  };
}

function fakeSecretStorage() {
  const values = new Map<string, string>();
  return {
    get: vi.fn(async (key: string) => values.get(key)),
    store: vi.fn(async (key: string, value: string) => {
      values.set(key, value);
    }),
    delete: vi.fn(async (key: string) => {
      values.delete(key);
    }),
  };
}

interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T | PromiseLike<T>): void;
  reject(error: unknown): void;
}

function deferred<T>(): Deferred<T> {
  let resolve: (value: T | PromiseLike<T>) => void = () => undefined;
  let reject: (error: unknown) => void = () => undefined;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

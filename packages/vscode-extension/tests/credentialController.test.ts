import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import {
  SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE,
  SUBVERSIONR_CREDENTIAL_STORE_INVALID,
  SUBVERSIONR_CREDENTIAL_TIMEOUT,
  SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE,
  type CredentialRequest,
  createCredentialController,
  createCredentialRequestHandler,
} from "../src/auth/credentialController";

describe("CredentialController", () => {
  it("returns a stored SecretStorage credential for non-interactive requests without prompting", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage });
    await secretStorage.store("subversionr.credential.v1.usernamePassword.66405412e36fad5c5c8f589fcce7183e434f5bc68b99742e30b02e56cc090733", JSON.stringify({
      version: 1,
      username: "alice",
      secret: "stored-secret",
    }));

    const response = await controller.handleCredentialRequest(request({ interactive: false }));

    expect(response).toEqual({
      requestId: "cred-1",
      action: "provide",
      credential: { username: "alice", secret: "stored-secret" },
      persistence: "secretStorage",
    });
    expect(controller.ui.promptUsername).not.toHaveBeenCalled();
    expect(controller.ui.promptSecret).not.toHaveBeenCalled();
  });

  it("cancels non-interactive requests with no stored credential and never prompts", async () => {
    const controller = createController();

    const response = await controller.handleCredentialRequest(request({ interactive: false }));

    expect(response).toMatchObject({
      requestId: "cred-1",
      action: "cancel",
      error: {
        code: SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE,
        category: "auth",
        messageKey: "error.auth.credentialNonInteractive",
        retryable: false,
      },
    });
    expect(controller.ui.promptUsername).not.toHaveBeenCalled();
    expect(controller.ui.promptSecret).not.toHaveBeenCalled();
  });

  it("cancels background requests with no stored credential even when interactive is incorrectly true", async () => {
    const controller = createController();

    const response = await controller.handleCredentialRequest(request({ origin: "background", interactive: true }));

    expect(response).toMatchObject({
      requestId: "cred-1",
      action: "cancel",
      error: {
        code: SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE,
        category: "auth",
        messageKey: "error.auth.credentialNonInteractive",
      },
    });
    expect(controller.ui.promptUsername).not.toHaveBeenCalled();
    expect(controller.ui.promptSecret).not.toHaveBeenCalled();
  });

  it("blocks untrusted workspaces before reading SecretStorage or prompting", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage, workspaceTrusted: false });

    const response = await controller.handleCredentialRequest(request());

    expect(response).toMatchObject({
      requestId: "cred-1",
      action: "cancel",
      error: {
        code: SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE,
        category: "lifecycle",
        messageKey: "error.auth.credentialUntrustedWorkspace",
      },
    });
    expect(secretStorage.get).not.toHaveBeenCalled();
    expect(controller.ui.promptUsername).not.toHaveBeenCalled();
    expect(controller.ui.promptSecret).not.toHaveBeenCalled();
  });

  it("stores interactive credentials only when the user chooses SecretStorage persistence", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({
      secretStorage,
      ui: fakeUi({
        username: "alice",
        secret: "new-secret",
        persistence: "secretStorage",
      }),
    });

    const response = await controller.handleCredentialRequest(request());

    expect(response).toEqual({
      requestId: "cred-1",
      action: "provide",
      credential: { username: "alice", secret: "new-secret" },
      persistence: "secretStorage",
    });
    expect(secretStorage.store).toHaveBeenCalledWith(
      "subversionr.credential.v1.usernamePassword.66405412e36fad5c5c8f589fcce7183e434f5bc68b99742e30b02e56cc090733",
      JSON.stringify({ version: 1, username: "alice", secret: "new-secret" }),
    );
  });

  it("indexes SecretStorage credentials and clears known saved credentials on request", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({
      secretStorage,
      ui: fakeUi({
        username: "alice",
        secret: "new-secret",
        persistence: "secretStorage",
      }),
    });
    const storageKey = credentialStorageKey("usernamePassword", "svn://example");

    await controller.handleCredentialRequest(request());

    expect(secretStorage.store).toHaveBeenCalledWith(
      "subversionr.credential.index.v1",
      JSON.stringify({ version: 1, keys: [storageKey] }),
    );
    await expect(controller.clearSavedCredentials()).resolves.toEqual({ deleted: 1 });
    expect(secretStorage.delete).toHaveBeenCalledWith(storageKey);
    expect(secretStorage.delete).toHaveBeenCalledWith("subversionr.credential.index.v1");

    const response = await controller.handleCredentialRequest(request({ requestId: "cred-2", interactive: false }));
    expect(response).toMatchObject({
      requestId: "cred-2",
      action: "cancel",
      error: {
        code: SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE,
      },
    });
  });

  it("stores the SecretStorage credential index before the credential payload", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({
      secretStorage,
      ui: fakeUi({
        username: "alice",
        secret: "new-secret",
        persistence: "secretStorage",
      }),
    });
    const storageKey = credentialStorageKey("usernamePassword", "svn://example");

    await controller.handleCredentialRequest(request());

    const indexStoreCall = secretStorage.store.mock.calls.findIndex(([key]) => key === "subversionr.credential.index.v1");
    const credentialStoreCall = secretStorage.store.mock.calls.findIndex(([key]) => key === storageKey);
    expect(indexStoreCall).toBeGreaterThanOrEqual(0);
    expect(credentialStoreCall).toBeGreaterThanOrEqual(0);
    expect(secretStorage.store.mock.invocationCallOrder[indexStoreCall]).toBeLessThan(
      secretStorage.store.mock.invocationCallOrder[credentialStoreCall],
    );
  });

  it("reports zero cleared credentials when no SecretStorage credential index exists", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage });

    await expect(controller.clearSavedCredentials()).resolves.toEqual({ deleted: 0 });

    expect(secretStorage.delete).not.toHaveBeenCalled();
  });

  it("uses a provided proxy username and prompts only for the proxy password", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({
      secretStorage,
      ui: fakeUi({
        secret: "proxy-secret",
        persistence: "secretStorage",
      }),
    });

    const response = await controller.handleCredentialRequest(
      request({ kind: "proxyPassword", username: "proxy-user" }),
    );

    expect(response).toEqual({
      requestId: "cred-1",
      action: "provide",
      credential: { username: "proxy-user", secret: "proxy-secret" },
      persistence: "secretStorage",
    });
    expect(controller.ui.promptUsername).not.toHaveBeenCalled();
    expect(controller.ui.promptSecret).toHaveBeenCalledWith(
      expect.objectContaining({ kind: "proxyPassword", username: "proxy-user" }),
      "proxy-user",
    );
    expect(secretStorage.store).toHaveBeenCalledWith(
      credentialStorageKey("proxyPassword", "svn://example"),
      JSON.stringify({ version: 1, username: "proxy-user", secret: "proxy-secret" }),
    );
  });

  it("prompts for a proxy username when the proxy challenge omits one", async () => {
    const controller = createController({
      ui: fakeUi({
        username: "proxy-user",
        secret: "proxy-secret",
      }),
    });

    const response = await controller.handleCredentialRequest(request({ kind: "proxyPassword" }));

    expect(response).toEqual({
      requestId: "cred-1",
      action: "provide",
      credential: { username: "proxy-user", secret: "proxy-secret" },
      persistence: "session",
    });
    expect(controller.ui.promptUsername).toHaveBeenCalledWith(expect.objectContaining({ kind: "proxyPassword" }));
    expect(controller.ui.promptSecret).toHaveBeenCalledWith(
      expect.objectContaining({ kind: "proxyPassword" }),
      "proxy-user",
    );
  });

  it.each([
    ["client certificate password", "clientCertificatePassword", undefined, { secret: "cert-secret" }],
    ["SSH passphrase", "sshPassphrase", "alice", { username: "alice", secret: "ssh-secret" }],
  ] as const)("prompts only for the %s secret", async (_label, kind, username, credential) => {
    const controller = createController({
      ui: fakeUi({
        secret: credential.secret,
      }),
    });

    const response = await controller.handleCredentialRequest(request({ kind, username }));

    expect(response).toEqual({
      requestId: "cred-1",
      action: "provide",
      credential,
      persistence: "session",
    });
    expect(controller.ui.promptUsername).not.toHaveBeenCalled();
    expect(controller.ui.promptSecret).toHaveBeenCalledWith(expect.objectContaining({ kind, username }), username);
  });

  it("uses a one-shot session credential when persistence is not allowed", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({
      secretStorage,
      ui: fakeUi({
        username: "alice",
        secret: "session-secret",
        persistence: "secretStorage",
      }),
    });

    const response = await controller.handleCredentialRequest(request({ persistenceAllowed: false }));

    expect(response).toEqual({
      requestId: "cred-1",
      action: "provide",
      credential: { username: "alice", secret: "session-secret" },
      persistence: "session",
    });
    expect(secretStorage.store).not.toHaveBeenCalled();
  });

  it("reuses an explicitly session-scoped credential for later non-interactive requests", async () => {
    const controller = createController({
      ui: fakeUi({
        username: "alice",
        secret: "session-secret",
        persistence: "session",
      }),
    });

    await expect(controller.handleCredentialRequest(request())).resolves.toEqual({
      requestId: "cred-1",
      action: "provide",
      credential: { username: "alice", secret: "session-secret" },
      persistence: "session",
    });

    const response = await controller.handleCredentialRequest(
      request({ requestId: "cred-2", interactive: false, origin: "background" }),
    );

    expect(response).toEqual({
      requestId: "cred-2",
      action: "provide",
      credential: { username: "alice", secret: "session-secret" },
      persistence: "session",
    });
    expect(controller.ui.promptUsername).toHaveBeenCalledTimes(1);
    expect(controller.ui.promptSecret).toHaveBeenCalledTimes(1);
  });

  it("does not reuse session credentials across credential kinds", async () => {
    const controller = createController({
      ui: fakeUi({
        username: "alice",
        secret: "session-secret",
        persistence: "session",
      }),
    });

    await controller.handleCredentialRequest(request());
    const response = await controller.handleCredentialRequest(
      request({ requestId: "cred-2", kind: "proxyPassword", username: "alice", interactive: false }),
    );

    expect(response).toMatchObject({
      requestId: "cred-2",
      action: "cancel",
      error: {
        code: SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE,
      },
    });
  });

  it("does not cache persistence-disallowed credentials as session credentials", async () => {
    const controller = createController({
      ui: fakeUi({
        username: "alice",
        secret: "one-shot-secret",
        persistence: "secretStorage",
      }),
    });

    await controller.handleCredentialRequest(request({ persistenceAllowed: false }));
    const response = await controller.handleCredentialRequest(request({ requestId: "cred-2", interactive: false }));

    expect(response).toMatchObject({
      requestId: "cred-2",
      action: "cancel",
      error: {
        code: SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE,
      },
    });
  });

  it("returns a stored secret-only client certificate password without prompting", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage });
    await secretStorage.store(
      credentialStorageKey("clientCertificatePassword", "svn://example"),
      JSON.stringify({
        version: 1,
        secret: "stored-cert-secret",
      }),
    );

    const response = await controller.handleCredentialRequest(
      request({ kind: "clientCertificatePassword", interactive: false }),
    );

    expect(response).toEqual({
      requestId: "cred-1",
      action: "provide",
      credential: { secret: "stored-cert-secret" },
      persistence: "secretStorage",
    });
    expect(controller.ui.promptUsername).not.toHaveBeenCalled();
    expect(controller.ui.promptSecret).not.toHaveBeenCalled();
  });

  it("rejects secret-only stored records for username credential challenges", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage });
    await secretStorage.store(
      credentialStorageKey("usernamePassword", "svn://example"),
      JSON.stringify({
        version: 1,
        secret: "stored-password",
      }),
    );

    const response = await controller.handleCredentialRequest(request({ interactive: false }));

    expect(response).toMatchObject({
      requestId: "cred-1",
      action: "cancel",
      error: {
        code: SUBVERSIONR_CREDENTIAL_STORE_INVALID,
        category: "auth",
        messageKey: "error.auth.credentialStoreInvalid",
      },
    });
    expect(controller.ui.promptUsername).not.toHaveBeenCalled();
    expect(controller.ui.promptSecret).not.toHaveBeenCalled();
  });

  it("does not return credentials across realms", async () => {
    const secretStorage = fakeSecretStorage();
    const controller = createController({ secretStorage });
    await secretStorage.store("subversionr.credential.v1.usernamePassword.66405412e36fad5c5c8f589fcce7183e434f5bc68b99742e30b02e56cc090733", JSON.stringify({
      version: 1,
      username: "alice",
      secret: "realm-a-secret",
    }));

    const response = await controller.handleCredentialRequest(
      request({ realm: "svn://other.example", interactive: false }),
    );

    expect(response).toMatchObject({
      action: "cancel",
      error: {
        code: SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE,
      },
    });
  });

  it("coalesces concurrent interactive prompts for the same realm and preserves request ids", async () => {
    const username = deferred<string | undefined>();
    const ui = fakeUi();
    ui.promptUsername.mockImplementation(async () => await username.promise);
    ui.promptSecret.mockResolvedValue("shared-secret");
    ui.pickPersistence.mockResolvedValue("session");
    const controller = createController({ ui });

    const first = controller.handleCredentialRequest(request({ requestId: "cred-1" }));
    const second = controller.handleCredentialRequest(request({ requestId: "cred-2" }));
    await flushMicrotasks();

    expect(ui.promptUsername).toHaveBeenCalledTimes(1);
    username.resolve("alice");

    await expect(Promise.all([first, second])).resolves.toEqual([
      {
        requestId: "cred-1",
        action: "provide",
        credential: { username: "alice", secret: "shared-secret" },
        persistence: "session",
      },
      {
        requestId: "cred-2",
        action: "provide",
        credential: { username: "alice", secret: "shared-secret" },
        persistence: "session",
      },
    ]);
    expect(ui.promptSecret).toHaveBeenCalledTimes(1);
  });

  it("does not return SecretStorage persistence to coalesced requests that disallow persistence", async () => {
    const username = deferred<string | undefined>();
    const ui = fakeUi();
    ui.promptUsername.mockImplementation(async () => await username.promise);
    ui.promptSecret.mockResolvedValue("shared-secret");
    ui.pickPersistence.mockResolvedValue("secretStorage");
    const controller = createController({ ui });

    const persisted = controller.handleCredentialRequest(request({ requestId: "cred-1", persistenceAllowed: true }));
    const sessionOnly = controller.handleCredentialRequest(request({ requestId: "cred-2", persistenceAllowed: false }));
    await flushMicrotasks();
    username.resolve("alice");

    await expect(Promise.all([persisted, sessionOnly])).resolves.toEqual([
      {
        requestId: "cred-1",
        action: "provide",
        credential: { username: "alice", secret: "shared-secret" },
        persistence: "secretStorage",
      },
      {
        requestId: "cred-2",
        action: "provide",
        credential: { username: "alice", secret: "shared-secret" },
        persistence: "session",
      },
    ]);
    expect(ui.promptUsername).toHaveBeenCalledTimes(1);
  });

  it("treats an interactive prompt timeout as credential cancel", async () => {
    const ui = fakeUi();
    ui.promptUsername.mockImplementation(() => new Promise<string | undefined>(() => undefined));
    const controller = createController({ ui });

    const response = await controller.handleCredentialRequest(request({ timeoutMs: 1 }));

    expect(response).toMatchObject({
      requestId: "cred-1",
      action: "cancel",
      error: {
        code: SUBVERSIONR_CREDENTIAL_TIMEOUT,
        category: "auth",
        messageKey: "error.auth.credentialTimeout",
        retryable: false,
      },
    });
    expect(ui.promptSecret).not.toHaveBeenCalled();
  });

  it("routes JSON-RPC credentials/request payloads into the credential controller", async () => {
    const controller = createController({
      ui: fakeUi({
        username: "alice",
        secret: "rpc-secret",
        persistence: "session",
      }),
    });
    const handler = createCredentialRequestHandler(controller);

    const response = await handler("credentials/request", request());

    expect(response).toEqual({
      requestId: "cred-1",
      action: "provide",
      credential: { username: "alice", secret: "rpc-secret" },
      persistence: "session",
    });
  });

  it("rejects unknown inbound credential methods with stable JSON-RPC errors", async () => {
    const handler = createCredentialRequestHandler(createController());

    await expect(handler("certificate/request", {})).rejects.toMatchObject({
      code: "RPC_METHOD_NOT_FOUND",
      category: "unsupported",
      messageKey: "error.rpc.methodNotFound",
      safeArgs: { method: "certificate/request" },
      retryable: false,
    });
  });
});

function createController(options: {
  workspaceTrusted?: boolean;
  secretStorage?: ReturnType<typeof fakeSecretStorage>;
  ui?: ReturnType<typeof fakeUi>;
} = {}) {
  const ui = options.ui ?? fakeUi();
  const controller = createCredentialController({
    workspaceTrusted: () => options.workspaceTrusted ?? true,
    secretStorage: options.secretStorage ?? fakeSecretStorage(),
    ui,
  });
  return Object.assign(controller, { ui });
}

function request(overrides: Partial<CredentialRequest> = {}): CredentialRequest {
  return {
    requestId: "cred-1",
    realm: "svn://example",
    kind: "usernamePassword",
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
  username?: string | undefined;
  secret?: string | undefined;
  persistence?: "secretStorage" | "session" | undefined;
} = {}) {
  return {
    promptUsername: vi.fn<(_request: CredentialRequest) => Promise<string | undefined>>(
      async () => options.username ?? "alice",
    ),
    promptSecret: vi.fn<(_request: CredentialRequest, _username: string | undefined) => Promise<string | undefined>>(
      async () => options.secret ?? "password",
    ),
    pickPersistence: vi.fn<(_request: CredentialRequest) => Promise<"secretStorage" | "session" | undefined>>(
      async () => options.persistence ?? "session",
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

function credentialStorageKey(kind: CredentialRequest["kind"], realm: string): string {
  const realmHash = createHash("sha256").update(`${kind}\0${realm}`, "utf8").digest("hex");
  return `subversionr.credential.v1.${kind}.${realmHash}`;
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

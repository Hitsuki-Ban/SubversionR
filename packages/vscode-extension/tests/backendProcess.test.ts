import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import {
  BackendLaunchError,
  type BackendChildProcess,
  type BackendProcessSpawner,
  startBackendProcess,
} from "../src/backend/backendProcess";
import { decodeContentLengthFrame, encodeContentLengthFrame } from "../src/transport/framing";

describe("startBackendProcess", () => {
  it("fails fast on non-absolute executable paths before spawning", async () => {
    const spawner = new RecordingSpawner();

    await expect(
      startBackendProcess(
        backendConfig({
          executablePath: "subversionr-daemon.exe",
        }),
        { spawner },
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_BACKEND_PATH_NOT_ABSOLUTE",
      category: "configuration",
      messageKey: "error.backend.executablePathNotAbsolute",
    });

    expect(spawner.calls).toHaveLength(0);
  });

  it("fails fast on non-absolute bridge paths before spawning", async () => {
    const spawner = new RecordingSpawner();

    await expect(
      startBackendProcess(
        backendConfig({
          bridgeDllPath: "subversionr_svn_bridge.dll",
        }),
        { spawner },
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_BACKEND_PATH_NOT_ABSOLUTE",
      category: "configuration",
      messageKey: "error.backend.bridgeDllPathNotAbsolute",
    });

    expect(spawner.calls).toHaveLength(0);
  });

  it("fails fast on non-absolute cache root paths before spawning", async () => {
    const spawner = new RecordingSpawner();

    await expect(
      startBackendProcess(
        backendConfig({
          cacheRoot: "SubversionR\\cache",
        }),
        { spawner },
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_BACKEND_PATH_NOT_ABSOLUTE",
      category: "configuration",
      messageKey: "error.backend.cacheRootNotAbsolute",
    });

    expect(spawner.calls).toHaveLength(0);
  });

  it("fails fast before spawning when the backend notification handler is missing", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), {
      spawner,
      requestHandler: async () => ({}),
    });

    expect(spawner.calls).toHaveLength(0);
    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_BACKEND_NOTIFICATION_HANDLER_REQUIRED",
      category: "configuration",
      messageKey: "error.backend.notificationHandlerRequired",
    });
  });

  it("spawns the sidecar over stdio and sends initialize with client context", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);

    expect(spawner.calls).toEqual([
      {
        executablePath: "C:\\SubversionR\\subversionr-daemon.exe",
        args: [],
        options: {
          env: {
            Path: "C:\\Windows\\System32",
            SUBVERSIONR_BRIDGE_DLL: "C:\\SubversionR\\subversionr_svn_bridge.dll",
          },
          shell: false,
          stdio: ["pipe", "pipe", "pipe"],
          windowsHide: true,
        },
      },
    ]);
    expect(request).toEqual({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        clientName: "SubversionR",
        clientVersion: "0.1.0",
        locale: "ja",
        workspaceTrust: "trusted",
        trustEpoch: 1,
        cacheRoot: "C:\\SubversionR\\cache",
      },
    });

    spawner.child.stdout.write(jsonRpcResponse(request.id, initializeResponse()));

    const connection = await start;
    expect(connection.initializeResult).toEqual(initializeResponse());
    expect(connection.initializeResult.capabilities.statusStaleNotification).toBe(true);

    connection.dispose();
  });

  it("sends the untrusted workspace state to the sidecar", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig({ workspaceTrust: "untrusted" }), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);

    expect(request).toMatchObject({
      method: "initialize",
      params: {
        workspaceTrust: "untrusted",
      },
    });

    spawner.child.stdout.write(jsonRpcResponse(request.id, initializeResponse()));

    const connection = await start;
    expect(connection.isRemoteSubmissionEnabled()).toBe(false);
    connection.dispose();
  });

  it("notifies request settlement after both daemon success and failure", async () => {
    const spawner = new RecordingSpawner();
    const onRequestSettled = vi.fn();
    const start = startBackendProcess(backendConfig(), backendDeps({ spawner, onRequestSettled }));
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;
    const params = {
      remote: { version: 1, operationId: "00000000-0000-4000-8000-000000000001" },
    };

    const success = connection.sendRequest("repository/checkout", params);
    const successRequest = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(successRequest.id, { revision: 1 }));
    await expect(success).resolves.toEqual({ revision: 1 });

    const failure = connection.sendRequest("repository/checkout", params);
    const failureRequest = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(encodeContentLengthFrame(JSON.stringify({
      jsonrpc: "2.0",
      id: failureRequest.id,
      error: { code: -32_000, message: "fixture failure" },
    })));
    await expect(failure).rejects.toBeDefined();

    expect(onRequestSettled).toHaveBeenNthCalledWith(1, "repository/checkout", params);
    expect(onRequestSettled).toHaveBeenNthCalledWith(2, "repository/checkout", params);
    connection.dispose();
  });

  it("notifies request settlement after AbortSignal cancellation", async () => {
    const spawner = new RecordingSpawner();
    const onRequestSettled = vi.fn();
    const start = startBackendProcess(backendConfig(), backendDeps({ spawner, onRequestSettled }));
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;
    const cancellation = new AbortController();
    const params = {
      remote: { version: 1, operationId: "00000000-0000-4000-8000-000000000001" },
    };

    const pending = connection.sendRequest("repository/checkout", params, { signal: cancellation.signal });
    await readJsonRpcRequest(spawner.child.stdin);
    cancellation.abort();

    await expect(pending).rejects.toBeDefined();
    expect(onRequestSettled).toHaveBeenCalledWith("repository/checkout", params);
    connection.dispose();
  });

  it("does not let request settlement cleanup replace the daemon result", async () => {
    const spawner = new RecordingSpawner();
    const start = startBackendProcess(backendConfig(), backendDeps({
      spawner,
      onRequestSettled: () => { throw new Error("cleanup fixture failure"); },
    }));
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;

    const response = connection.sendRequest("diagnostics/get", {});
    const request = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(request.id, { source: "subversionr-daemon" }));

    await expect(response).resolves.toEqual({ source: "subversionr-daemon" });
    connection.dispose();
  });

  it("keeps remote submission disabled until the exact trust update acknowledgement arrives", async () => {
    const spawner = new RecordingSpawner();
    const start = startBackendProcess(
      backendConfig({ workspaceTrust: "untrusted" }),
      backendDeps({ spawner }),
    );
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;

    const update = connection.updateWorkspaceTrust(true);
    expect(connection.isRemoteSubmissionEnabled()).toBe(false);
    const updateRequest = await readJsonRpcRequest(spawner.child.stdin);
    expect(updateRequest).toEqual({
      jsonrpc: "2.0",
      id: 2,
      method: "workspaceTrust/update",
      params: { trusted: true, trustEpoch: 2 },
    });
    expect(connection.isRemoteSubmissionEnabled()).toBe(false);

    spawner.child.stdout.write(
      jsonRpcResponse(updateRequest.id, { acknowledgedTrustEpoch: 2 }),
    );

    await expect(update).resolves.toBe(2);
    expect(connection.isRemoteSubmissionEnabled()).toBe(true);
    connection.dispose();
  });

  it("rejects concurrent trust updates and disables remote submission while revocation is pending", async () => {
    const spawner = new RecordingSpawner();
    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;
    expect(connection.isRemoteSubmissionEnabled()).toBe(true);

    const update = connection.updateWorkspaceTrust(false);
    expect(connection.isRemoteSubmissionEnabled()).toBe(false);
    await expect(connection.updateWorkspaceTrust(true)).rejects.toMatchObject({
      code: "SUBVERSIONR_REMOTE_TRUST_UPDATE_IN_PROGRESS",
      category: "protocol",
      messageKey: "error.remote.trustUpdateInProgress",
    });
    const updateRequest = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(
      jsonRpcResponse(updateRequest.id, { acknowledgedTrustEpoch: 2 }),
    );

    await expect(update).resolves.toBe(2);
    expect(connection.isRemoteSubmissionEnabled()).toBe(false);
    connection.dispose();
  });

  it.each([
    { acknowledgedTrustEpoch: 3 },
    { acknowledgedTrustEpoch: 2, unexpected: true },
  ])("rejects a non-exact trust update acknowledgement and remains disabled", async (acknowledgement) => {
    const spawner = new RecordingSpawner();
    const start = startBackendProcess(
      backendConfig({ workspaceTrust: "untrusted" }),
      backendDeps({ spawner }),
    );
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;

    const update = connection.updateWorkspaceTrust(true);
    const updateRequest = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(updateRequest.id, acknowledgement));

    await expect(update).rejects.toMatchObject({
      code: "SUBVERSIONR_REMOTE_TRUST_ACK_INVALID",
      category: "protocol",
      messageKey: "error.remote.trustAckInvalid",
    });
    expect(connection.isRemoteSubmissionEnabled()).toBe(false);
    connection.dispose();
  });

  it("rejects initialize and terminates the sidecar when protocol major is unsupported", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);

    spawner.child.stdout.write(
      jsonRpcResponse(
        request.id,
        initializeResponse({
          protocol: { major: 2, minor: 0 },
        }),
      ),
    );

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_PROTOCOL_MAJOR_UNSUPPORTED",
      category: "protocol",
      messageKey: "error.backend.protocolMajorUnsupported",
      safeArgs: {
        expected: 1,
        actual: 2,
      },
    });
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
  });

  it("rejects initialize and terminates the sidecar when protocol minor is too old", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);

    spawner.child.stdout.write(
      jsonRpcResponse(
        request.id,
        initializeResponse({
          protocol: { major: 1, minor: 33 },
        }),
      ),
    );

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_PROTOCOL_MINOR_UNSUPPORTED",
      category: "protocol",
      messageKey: "error.backend.protocolMinorUnsupported",
      safeArgs: {
        expectedMinimum: 34,
        actual: 33,
      },
    });
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
  });

  it("rejects initialize and terminates the sidecar when required fields are missing", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);

    spawner.child.stdout.write(
      jsonRpcResponse(request.id, {
        protocol: { major: 1, minor: 0 },
      }),
    );

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_INITIALIZE_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.backend.initializeResponseInvalid",
      safeArgs: {
        field: "backendVersion",
      },
    });
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
  });

  it("rejects initialize when the sidecar acknowledges a different initial trust epoch", async () => {
    const spawner = new RecordingSpawner();
    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);

    spawner.child.stdout.write(
      jsonRpcResponse(request.id, initializeResponse({ acknowledgedTrustEpoch: 2 })),
    );

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_INITIALIZE_RESPONSE_INVALID",
      category: "protocol",
      safeArgs: { field: "acknowledgedTrustEpoch" },
    });
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
  });

  it("rejects initialize and terminates the sidecar when cache schema is missing", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);
    const response: Record<string, unknown> = initializeResponse();
    delete response.cacheSchema;

    spawner.child.stdout.write(jsonRpcResponse(request.id, response));

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_INITIALIZE_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.backend.initializeResponseInvalid",
      safeArgs: {
        field: "cacheSchema",
      },
    });
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
  });

  it("rejects initialize and terminates the sidecar when cache schema is unsupported", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);

    spawner.child.stdout.write(
      jsonRpcResponse(
        request.id,
        initializeResponse({
          cacheSchema: {
            schemaId: "subversionr.cache.v2",
            version: 2,
            rollback: "delete-and-reconcile",
          },
        }),
      ),
    );

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_CACHE_SCHEMA_UNSUPPORTED",
      category: "protocol",
      messageKey: "error.backend.cacheSchemaUnsupported",
      safeArgs: {
        schemaId: "subversionr.cache.v2",
        version: 2,
      },
    });
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
  });

  it("reports the unsupported cache rollback policy in safe args", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);

    spawner.child.stdout.write(
      jsonRpcResponse(
        request.id,
        initializeResponse({
          cacheSchema: {
            schemaId: "subversionr.cache.v1",
            version: 1,
            rollback: "preserve-and-migrate",
          },
        }),
      ),
    );

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_CACHE_SCHEMA_UNSUPPORTED",
      category: "protocol",
      messageKey: "error.backend.cacheSchemaUnsupported",
      safeArgs: {
        schemaId: "subversionr.cache.v1",
        version: 1,
        rollback: "preserve-and-migrate",
      },
    });
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
  });

  it("rejects initialize and terminates the sidecar when content-length framing is unavailable", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const request = await readJsonRpcRequest(spawner.child.stdin);

    spawner.child.stdout.write(
      jsonRpcResponse(
        request.id,
        initializeResponse({
          capabilities: {
            ...initializeResponse().capabilities,
            contentLengthFraming: false,
          },
        }),
      ),
    );

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_BACKEND_CAPABILITY_REQUIRED",
      category: "protocol",
      messageKey: "error.backend.capabilityRequired",
      safeArgs: {
        capability: "contentLengthFraming",
      },
    });
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
  });

  it.each([
    "realLibsvnBridge",
    "repositoryDiscover",
    "repositoryOpen",
    "repositoryClose",
    "repositoryCheckout",
    "statusSnapshot",
    "statusRefresh",
    "statusRemoteCheck",
    "contentGet",
    "contentGetRevision",
    "historyLog",
    "historyBlame",
    "operationRun",
    "operationRunAdd",
    "operationRunRemove",
    "operationRunMove",
    "operationRunCleanup",
    "operationRunResolve",
    "operationRunUpdate",
    "operationRunUpdateSelectedPath",
    "operationRunUpdateToRevision",
    "operationRunUpdateDepth",
    "operationRunUpdateExternalsPolicy",
    "propertiesList",
    "operationRunPropertySet",
    "operationRunPropertyDelete",
    "ignore",
    "operationRunChangelistSet",
    "operationRunChangelistClear",
    "operationRunLock",
    "operationRunUnlock",
    "operationRunBranchCreate",
    "operationRunSwitch",
    "operationRunCommit",
    "operationRunCommitMultiPath",
    "diagnosticsGet",
    "credentialRequest",
    "certificateRequest",
    "remoteOperationEnvelope",
    "trustedConfigSnapshot",
    "remoteWorkerIsolation",
    "credentialLeaseSettlement",
    "remoteConnectionState",
  ] as const)(
    "rejects initialize and terminates the sidecar when %s is unavailable",
    async (capability) => {
      const spawner = new RecordingSpawner();

      const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
      const request = await readJsonRpcRequest(spawner.child.stdin);

      spawner.child.stdout.write(
        jsonRpcResponse(
          request.id,
          initializeResponse({
            capabilities: {
              ...initializeResponse().capabilities,
              [capability]: false,
            },
          }),
        ),
      );

      await expect(start).rejects.toMatchObject({
        code: "SUBVERSIONR_BACKEND_CAPABILITY_REQUIRED",
        category: "protocol",
        messageKey: "error.backend.capabilityRequired",
        safeArgs: {
          capability,
        },
      });
      expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
    },
  );

  it("rejects pending initialize when the sidecar exits and keeps stderr diagnostic context", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stderr.write("native bridge library is missing\n");
    spawner.child.exit(2, null);

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_BACKEND_EXITED",
      category: "process",
      messageKey: "error.backend.exitedDuringInitialize",
      safeArgs: {
        exitCode: 2,
        signal: null,
        stderr: "native bridge library is missing\n",
      },
    });
  });

  it("surfaces a strict daemon startup record without parsing native loader prose", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.emit("exit", 2, null);
    spawner.child.stderr.write(
      `${JSON.stringify({
        schema: "subversionr.daemon.startup-error.v1",
        code: "SUBVERSIONR_NATIVE_BRIDGE_SYMBOL_MISSING",
        category: "process",
        messageKey: "error.backend.nativeBridgeSymbolMissing",
        safeArgs: {},
        retryable: false,
        diagnostics: null,
      })}\n`,
    );
    spawner.child.emit("close", 2, null);

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_NATIVE_BRIDGE_SYMBOL_MISSING",
      category: "process",
      messageKey: "error.backend.nativeBridgeSymbolMissing",
      safeArgs: {},
      retryable: false,
      diagnostics: null,
    });
  });

  it("bounds initialize failure when exit occurs but stdio close never arrives", async () => {
    vi.useFakeTimers();
    try {
      const spawner = new RecordingSpawner();
      const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
      await readJsonRpcRequest(spawner.child.stdin);
      spawner.child.stderr.write("native bridge process stopped\n");
      spawner.child.emit("exit", 2, null);

      const failure = expect(start).rejects.toMatchObject({
        code: "SUBVERSIONR_BACKEND_EXITED",
        safeArgs: {
          exitCode: 2,
          signal: null,
          stderr: "native bridge process stopped\n",
        },
      });
      await vi.advanceTimersByTimeAsync(250);
      await failure;
    } finally {
      vi.useRealTimers();
    }
  });

  it("rejects pending initialize when the sidecar fails to spawn", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.emit("error", new Error("spawn ENOENT"));

    await expect(start).rejects.toMatchObject({
      code: "SUBVERSIONR_BACKEND_SPAWN_FAILED",
      category: "process",
      messageKey: "error.backend.spawnFailed",
      safeArgs: {
        message: "spawn ENOENT",
      },
    });
  });

  it("terminates the sidecar when initialize transport framing fails", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write("Bad-Header: 1\r\n\r\n{}");

    await expect(start).rejects.toThrow("Invalid Content-Length header");
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
  });

  it("sends shutdown before disposing an initialized sidecar", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;

    const shutdown = connection.shutdown();
    const shutdownRequest = await readJsonRpcRequest(spawner.child.stdin);
    expect(shutdownRequest).toEqual({
      jsonrpc: "2.0",
      id: 2,
      method: "shutdown",
      params: {},
    });

    spawner.child.stdout.write(jsonRpcResponse(shutdownRequest.id, { accepted: true }));

    await shutdown;
    expect(spawner.child.killCalls).toEqual([]);
  });

  it("keeps the initialized connection available as a JSON-RPC sender", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;

    const refresh = connection.sendRequest<{ generation: number }>("status/refresh", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
    });
    const refreshRequest = await readJsonRpcRequest(spawner.child.stdin);

    expect(refreshRequest).toEqual({
      jsonrpc: "2.0",
      id: 2,
      method: "status/refresh",
      params: {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
      },
    });

    spawner.child.stdout.write(jsonRpcResponse(refreshRequest.id, { generation: 8 }));

    await expect(refresh).resolves.toEqual({ generation: 8 });
    connection.dispose();
  });

  it("notifies once when an initialized sidecar exits unexpectedly", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;
    const events: unknown[] = [];

    connection.onDidTerminate((event) => {
      events.push(event);
    });
    spawner.child.exit(9, null);

    expect(events).toEqual([
      {
        reason: "processExit",
        exitCode: 9,
        signal: null,
      },
    ]);
    expect(spawner.child.killCalls).toEqual([]);
  });

  it("does not notify termination listeners for explicit disposal", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), backendDeps({ spawner }));
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;
    const events: unknown[] = [];

    connection.onDidTerminate((event) => {
      events.push(event);
    });
    connection.dispose();
    spawner.child.exit(null, "SIGTERM");

    expect(events).toEqual([]);
  });

  it("routes daemon initiated credential requests through the client request handler", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), {
      spawner,
      notificationHandler: () => {},
      requestHandler: async (method, params) => {
        expect(method).toBe("credentials/request");
        expect(params).toEqual({ requestId: "cred-1", realm: "svn://example", kind: "usernamePassword" });
        return { requestId: "cred-1", action: "cancel" };
      },
    });
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;

    spawner.child.stdout.write(
      encodeContentLengthFrame(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 12,
          method: "credentials/request",
          params: { requestId: "cred-1", realm: "svn://example", kind: "usernamePassword" },
        }),
      ),
    );

    const response = await readJsonRpcRequest(spawner.child.stdin);
    expect(response).toEqual({
      jsonrpc: "2.0",
      id: 12,
      result: { requestId: "cred-1", action: "cancel" },
    });

    connection.dispose();
  });

  it("routes daemon initiated notifications through the client notification handler without responding", async () => {
    const spawner = new RecordingSpawner();
    const notifications: unknown[] = [];

    const start = startBackendProcess(backendConfig(), {
      spawner,
      notificationHandler: (method, params) => {
        notifications.push({ method, params });
      },
    });
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;

    spawner.child.stdout.write(
      encodeContentLengthFrame(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "status/stale",
          params: {
            repositoryId: "repo-uuid:C:/wc",
            epoch: 7,
            reason: "backendRestart",
            timestamp: "2026-06-22T00:03:00Z",
            source: "daemon-status-stale",
          },
        }),
      ),
    );
    await flushMicrotasks();

    expect(notifications).toEqual([
      {
        method: "status/stale",
        params: {
          repositoryId: "repo-uuid:C:/wc",
          epoch: 7,
          reason: "backendRestart",
          timestamp: "2026-06-22T00:03:00Z",
          source: "daemon-status-stale",
        },
      },
    ]);
    expect(spawner.child.stdin.readableLength).toBe(0);

    connection.dispose();
  });

  it("terminates the initialized sidecar when daemon initiated notification handling fails", async () => {
    const spawner = new RecordingSpawner();

    const start = startBackendProcess(backendConfig(), {
      spawner,
      notificationHandler: () => {
        throw new Error("SUBVERSIONR_BACKEND_NOTIFICATION_UNSUPPORTED");
      },
    });
    const initialize = await readJsonRpcRequest(spawner.child.stdin);
    spawner.child.stdout.write(jsonRpcResponse(initialize.id, initializeResponse()));
    const connection = await start;
    const events: unknown[] = [];
    connection.onDidTerminate((event) => {
      events.push(event);
    });

    spawner.child.stdout.write(
      encodeContentLengthFrame(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "watcher/overflow",
          params: {
            repositoryId: "repo-uuid:C:/wc",
            epoch: 7,
            timestamp: "2026-06-25T00:00:00Z",
          },
        }),
      ),
    );
    await flushMicrotasks();

    expect(events).toEqual([
      {
        reason: "protocolFault",
        message: "SUBVERSIONR_BACKEND_NOTIFICATION_UNSUPPORTED",
      },
    ]);
    expect(spawner.child.killCalls).toEqual(["SIGTERM"]);
    await expect(connection.sendRequest("diagnostics/get", {})).rejects.toThrow("JSON-RPC stream client is disposed");
  });
});

class RecordingSpawner implements BackendProcessSpawner {
  public readonly child = new FakeChildProcess();
  public readonly calls: Array<{
    executablePath: string;
    args: readonly string[];
    options: unknown;
  }> = [];

  public spawn(executablePath: string, args: readonly string[], options: unknown): BackendChildProcess {
    this.calls.push({ executablePath, args, options });
    return this.child;
  }
}

class FakeChildProcess extends EventEmitter implements BackendChildProcess {
  public readonly stdin = new PassThrough();
  public readonly stdout = new PassThrough();
  public readonly stderr = new PassThrough();
  public readonly killCalls: Array<NodeJS.Signals | number | undefined> = [];
  public pid = 1234;

  public kill(signal?: NodeJS.Signals | number): boolean {
    this.killCalls.push(signal);
    return true;
  }

  public exit(code: number | null, signal: NodeJS.Signals | null): void {
    this.emit("exit", code, signal);
    this.emit("close", code, signal);
  }
}

function backendConfig(
  overrides: Partial<Parameters<typeof startBackendProcess>[0]> = {},
): Parameters<typeof startBackendProcess>[0] {
  return {
    executablePath: "C:\\SubversionR\\subversionr-daemon.exe",
    bridgeDllPath: "C:\\SubversionR\\subversionr_svn_bridge.dll",
    cacheRoot: "C:\\SubversionR\\cache",
    clientName: "SubversionR",
    clientVersion: "0.1.0",
    locale: "ja",
    workspaceTrust: "trusted",
    baseEnv: {
      Path: "C:\\Windows\\System32",
    },
    ...overrides,
  };
}

async function readJsonRpcRequest(stream: PassThrough): Promise<Record<string, unknown>> {
  const chunk = await new Promise<Buffer>((resolve) => {
    stream.once("data", (data: Buffer) => resolve(data));
  });
  return JSON.parse(decodeContentLengthFrame(chunk.toString("utf8"))) as Record<string, unknown>;
}

function jsonRpcResponse(id: unknown, result: unknown): string {
  return encodeContentLengthFrame(JSON.stringify({ jsonrpc: "2.0", id, result }));
}

function backendDeps(
  overrides: NonNullable<Parameters<typeof startBackendProcess>[1]>,
): NonNullable<Parameters<typeof startBackendProcess>[1]> {
  return {
    notificationHandler: () => {},
    ...overrides,
  };
}

async function flushMicrotasks(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
}

function initializeResponse(
  overrides: Partial<ReturnType<typeof initializeResponseBase>> = {},
): ReturnType<typeof initializeResponseBase> {
  return {
    ...initializeResponseBase(),
    ...overrides,
  };
}

function initializeResponseBase() {
  return {
    protocol: { major: 1, minor: 34 },
    backendVersion: "0.1.0",
    bridgeVersion: "subversionr-svn-bridge/0.1.0",
    libsvnVersion: "1.14.5",
    platform: { os: "windows", arch: "x86_64" },
    cacheSchema: {
      schemaId: "subversionr.cache.v1",
      version: 1,
      rollback: "delete-and-reconcile",
    },
    capabilities: {
      contentLengthFraming: true,
      realLibsvnBridge: true,
      repositoryDiscover: true,
      repositoryOpen: true,
      repositoryClose: true,
      repositoryCheckout: true,
      statusSnapshot: true,
      statusRefresh: true,
      statusRemoteCheck: true,
      statusStaleNotification: true,
      contentGet: true,
      contentGetRevision: true,
      historyLog: true,
      historyBlame: true,
      operationRun: true,
      operationRunAdd: true,
      operationRunRemove: true,
      operationRunMove: true,
      operationRunCleanup: true,
      operationRunResolve: true,
      operationRunUpdate: true,
      operationRunUpdateSelectedPath: true,
      operationRunUpdateToRevision: true,
      operationRunUpdateDepth: true,
      operationRunUpdateExternalsPolicy: true,
      propertiesList: true,
      operationRunPropertySet: true,
      operationRunPropertyDelete: true,
      ignore: true,
      operationRunChangelistSet: true,
      operationRunChangelistClear: true,
      operationRunLock: true,
      operationRunUnlock: true,
      operationRunBranchCreate: true,
      operationRunSwitch: true,
      operationRunCommit: true,
      operationRunCommitMultiPath: true,
      diagnosticsGet: true,
      credentialRequest: true,
      certificateRequest: true,
      remoteOperationEnvelope: true,
      trustedConfigSnapshot: true,
      remoteWorkerIsolation: true,
      credentialLeaseSettlement: true,
      remoteConnectionState: true,
    },
    acknowledgedTrustEpoch: 1,
  };
}

expect(BackendLaunchError).toBeDefined();

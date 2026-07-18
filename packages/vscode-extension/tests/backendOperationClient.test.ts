import { describe, expect, it, vi } from "vitest";
import { BackendOperationClient } from "../src/operations/backendOperationClient";
import type { BackendConnection, InitializeResult } from "../src/backend/backendProcess";
import type { BackendService } from "../src/backend/backendService";
import type { OperationRunResponse } from "../src/operations/operationRunRpcClient";
import { anonymousSvnRemoteEnvelope } from "./remoteOperationEnvelopeFixture";

describe("BackendOperationClient", () => {
  it("initializes the backend and sends revert operation/run through the active connection", async () => {
    const response = operationResponse();
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.revert({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      depth: "empty",
      changelists: [],
      clearChangelists: false,
      metadataOnly: false,
      addedKeepLocal: false,
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "revert",
      options: {
        version: 1,
        paths: ["src/main.c"],
        depth: "empty",
        changelists: [],
        clearChangelists: false,
        metadataOnly: false,
        addedKeepLocal: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends add operation/run through the active connection", async () => {
    const response = operationResponse({ kind: "add", path: "scratch.txt", reason: "operationAdd" });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.add({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["scratch.txt"],
      depth: "empty",
      force: false,
      noIgnore: false,
      noAutoprops: false,
      addParents: false,
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "add",
      options: {
        version: 1,
        paths: ["scratch.txt"],
        depth: "empty",
        force: false,
        noIgnore: false,
        noAutoprops: false,
        addParents: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends remove operation/run through the active connection", async () => {
    const response = operationResponse({ kind: "remove", path: "src/old.c", reason: "operationRemove" });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.remove({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/old.c"],
      force: false,
      keepLocal: false,
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "remove",
      options: {
        version: 1,
        paths: ["src/old.c"],
        force: false,
        keepLocal: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends move operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "move",
      path: "src/renamed.c",
      reason: "operationMove",
      reconcile: {
        targets: [
          { path: "src", depth: "immediates", reason: "operationMove" },
        ],
        requiresFullReconcile: false,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.move({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      sourcePath: "src/old.c",
      destinationPath: "src/renamed.c",
      makeParents: false,
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "move",
      options: {
        version: 1,
        sourcePath: "src/old.c",
        destinationPath: "src/renamed.c",
        makeParents: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends cleanup operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "cleanup",
      path: ".",
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.cleanup({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
      breakLocks: true,
      fixRecordedTimestamps: false,
      clearDavCache: false,
      vacuumPristines: false,
      includeExternals: false,
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "cleanup",
      options: {
        version: 1,
        path: ".",
        breakLocks: true,
        fixRecordedTimestamps: false,
        clearDavCache: false,
        vacuumPristines: false,
        includeExternals: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends upgrade operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "upgrade",
      path: ".",
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.upgrade({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "upgrade",
      options: {
        version: 1,
        path: ".",
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends update operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "update",
      path: ".",
      revision: 8,
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.update({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "update",
      options: {
        version: 1,
        path: ".",
        revision: "head",
        depth: "workingCopy",
        depthIsSticky: false,
        ignoreExternals: true,
      },
    });
    expect(result).toEqual(response);
  });

  it("passes cancellation signals from update requests to the active connection", async () => {
    const response = operationResponse({
      kind: "update",
      path: ".",
      revision: 8,
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);
    const cancellation = new AbortController();

    await client.update(
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: ".",
        revision: "head",
        depth: "workingCopy",
        depthIsSticky: false,
        ignoreExternals: true,
        remote: anonymousSvnRemoteEnvelope(),
      },
      { signal: cancellation.signal },
    );

    expect(connection.sendRequest).toHaveBeenCalledWith(
      "operation/run",
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        remote: anonymousSvnRemoteEnvelope(),
        kind: "update",
        options: {
          version: 1,
          path: ".",
          revision: "head",
          depth: "workingCopy",
          depthIsSticky: false,
          ignoreExternals: true,
        },
      },
      { signal: cancellation.signal },
    );
  });

  it("sends update operation/run with numeric revision, sparse depth, sticky depth, and externals policy", async () => {
    const response = operationResponse({
      kind: "update",
      path: "src",
      revision: 42,
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.update({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
      revision: 42,
      depth: "files",
      depthIsSticky: true,
      ignoreExternals: false,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "update",
      options: {
        version: 1,
        path: "src",
        revision: 42,
        depth: "files",
        depthIsSticky: true,
        ignoreExternals: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends selected-path update operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "update",
      path: "src/main.c",
      revision: 8,
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.update({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "update",
      options: {
        version: 1,
        path: "src/main.c",
        revision: "head",
        depth: "workingCopy",
        depthIsSticky: false,
        ignoreExternals: true,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends branchCreate operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "branchCreate",
      revision: 42,
      reconcile: {
        targets: [],
        requiresFullReconcile: false,
      },
    });
    response.touchedPaths = [];
    response.summary = { affectedPaths: 0, skippedPaths: 0 };
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.branchCreate({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      sourceUrl: "svn://svn.example.invalid/repo/trunk",
      destinationUrl: "svn://svn.example.invalid/repo/branches/feature",
      revision: "head",
      message: "Create feature branch",
      makeParents: true,
      ignoreExternals: false,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "branchCreate",
      options: {
        version: 1,
        sourceUrl: "svn://svn.example.invalid/repo/trunk",
        destinationUrl: "svn://svn.example.invalid/repo/branches/feature",
        revision: "head",
        message: "Create feature branch",
        makeParents: true,
        ignoreExternals: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends switch operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "switch",
      path: "src",
      revision: 55,
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.switch({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
      url: "svn://svn.example.invalid/repo/branches/feature/src",
      revision: 55,
      depth: "infinity",
      depthIsSticky: true,
      ignoreExternals: true,
      ignoreAncestry: false,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "switch",
      options: {
        version: 1,
        path: "src",
        url: "svn://svn.example.invalid/repo/branches/feature/src",
        revision: 55,
        depth: "infinity",
        depthIsSticky: true,
        ignoreExternals: true,
        ignoreAncestry: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends relocate operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "relocate",
      path: ".",
      revision: null,
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.relocate({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      fromUrl: "file:///repo",
      toUrl: "https://svn.example.invalid/repo",
      ignoreExternals: true,
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "relocate",
      options: {
        version: 1,
        fromUrl: "file:///repo",
        toUrl: "https://svn.example.invalid/repo",
        ignoreExternals: true,
      },
    });
    expect(result).toEqual(response);
  });

  it("passes cancellation signals from switch requests to the active connection", async () => {
    const response = operationResponse({
      kind: "switch",
      path: "src",
      revision: 55,
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);
    const cancellation = new AbortController();

    await client.switch(
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src",
        url: "svn://svn.example.invalid/repo/branches/feature/src",
        revision: 55,
        depth: "infinity",
        depthIsSticky: true,
        ignoreExternals: true,
        ignoreAncestry: false,
        remote: anonymousSvnRemoteEnvelope(),
      },
      { signal: cancellation.signal },
    );

    expect(connection.sendRequest).toHaveBeenCalledWith(
      "operation/run",
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        remote: anonymousSvnRemoteEnvelope(),
        kind: "switch",
        options: {
          version: 1,
          path: "src",
          url: "svn://svn.example.invalid/repo/branches/feature/src",
          revision: 55,
          depth: "infinity",
          depthIsSticky: true,
          ignoreExternals: true,
          ignoreAncestry: false,
        },
      },
      { signal: cancellation.signal },
    );
  });

  it("initializes the backend and sends propertySet operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "propertySet",
      path: "src",
      reason: "operationPropertySet",
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.propertySet({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
      name: "svn:ignore",
      value: "target\nnode_modules",
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "propertySet",
      options: {
        version: 1,
        path: "src",
        name: "svn:ignore",
        value: "target\nnode_modules",
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends propertyDelete operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "propertyDelete",
      path: "src",
      reason: "operationPropertyDelete",
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.propertyDelete({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
      name: "svn:ignore",
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "propertyDelete",
      options: {
        version: 1,
        path: "src",
        name: "svn:ignore",
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends changelistSet operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "changelistSet",
      path: "src/main.c",
      reason: "operationChangelistSet",
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.changelistSet({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      depth: "empty",
      changelist: "review",
      changelists: [],
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "changelistSet",
      options: {
        version: 1,
        paths: ["src/main.c"],
        depth: "empty",
        changelist: "review",
        changelists: [],
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends changelistClear operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "changelistClear",
      path: "src/main.c",
      reason: "operationChangelistClear",
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.changelistClear({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      depth: "empty",
      changelists: ["review"],
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "changelistClear",
      options: {
        version: 1,
        paths: ["src/main.c"],
        depth: "empty",
        changelists: ["review"],
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends lock operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "lock",
      path: "src/main.c",
      reason: "operationLock",
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.lock({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      comment: null,
      stealLock: false,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "lock",
      options: {
        version: 1,
        paths: ["src/main.c"],
        comment: null,
        stealLock: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends unlock operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "unlock",
      path: "src/main.c",
      reason: "operationUnlock",
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.unlock({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      breakLock: false,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "unlock",
      options: {
        version: 1,
        paths: ["src/main.c"],
        breakLock: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends commit operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "commit",
      path: "src/main.c",
      revision: 9,
      reason: "operationCommit",
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.commit({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      message: "commit tracked file",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "commit",
      options: {
        version: 1,
        paths: ["src/main.c"],
        message: "commit tracked file",
        depth: "empty",
        changelists: [],
        keepLocks: false,
        keepChangelists: false,
        commitAsOperations: false,
        includeFileExternals: false,
        includeDirExternals: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("initializes the backend and sends resolve operation/run through the active connection", async () => {
    const response = operationResponse({
      kind: "resolve",
      path: "src/conflicted.txt",
      reason: "operationResolve",
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.resolve({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/conflicted.txt"],
      depth: "empty",
      choice: "working",
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "resolve",
      options: {
        version: 1,
        paths: ["src/conflicted.txt"],
        depth: "empty",
        choice: "working",
      },
    });
    expect(result).toEqual(response);
  });

  it("sends explicit theirs-full resolve choices through operation/run", async () => {
    const response = operationResponse({
      kind: "resolve",
      path: "src/conflicted.txt",
      reason: "operationResolve",
    });
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendOperationClient(service);

    const result = await client.resolve({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/conflicted.txt"],
      depth: "empty",
      choice: "theirsFull",
    });

    expect(connection.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "resolve",
      options: {
        version: 1,
        paths: ["src/conflicted.txt"],
        depth: "empty",
        choice: "theirsFull",
      },
    });
    expect(result).toEqual(response);
  });
});

function fakeConnection(response: OperationRunResponse): BackendConnection {
  return {
    initializeResult: initializeResult(),
    sendRequest: vi.fn().mockResolvedValue(response),
    isRemoteSubmissionEnabled: vi.fn(() => true),
    currentRemoteTrustEpoch: vi.fn(() => 1),
    updateWorkspaceTrust: vi.fn(async () => 2),
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn().mockResolvedValue(undefined),
    dispose: vi.fn(),
  };
}

function operationResponse(
  options: {
    kind?: string;
    path?: string;
    reason?: string;
    revision?: number | null;
    reconcile?: OperationRunResponse["reconcile"];
  } = {},
): OperationRunResponse {
  const kind = options.kind ?? "revert";
  const path = options.path ?? "src/main.c";
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    operationId: "op-1",
    kind,
    touchedPaths: [path],
    revision: options.revision ?? null,
    summary: {
      affectedPaths: 1,
      skippedPaths: 0,
    },
    warnings: [],
    reconcile: options.reconcile ?? {
      targets: [{ path, depth: "empty", reason: options.reason ?? "operationRevert" }],
      requiresFullReconcile: false,
    },
  };
}

function initializeResult(): InitializeResult {
  return {
    protocol: { major: 1, minor: 35 },
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
      remoteSvnAnonymous: true,
    },
    acknowledgedTrustEpoch: 1,
  };
}

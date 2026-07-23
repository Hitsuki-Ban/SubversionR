import { describe, expect, it, vi } from "vitest";
import {
  OperationRunResponseError,
  OperationRunRpcClient,
  type ResolveOperationChoice,
  type OperationRunResponse,
} from "../src/operations/operationRunRpcClient";
import type { JsonRpcSender } from "../src/status/types";
import { anonymousSvnRemoteEnvelope } from "./remoteOperationEnvelopeFixture";

describe("OperationRunRpcClient", () => {
  it("sends operation/run revert with explicit options and returns the parsed result", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse()),
    };
    const client = new OperationRunRpcClient(sender);

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

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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
    expect(result).toEqual(operationResponse());
  });

  it("sends operation/run add with explicit options and returns the parsed result", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse({ kind: "add", reason: "operationAdd" })),
    };
    const client = new OperationRunRpcClient(sender);

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

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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
    expect(result).toEqual(operationResponse({ kind: "add", reason: "operationAdd" }));
  });

  it("sends operation/run remove with explicit options and returns the parsed result", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse({ kind: "remove", reason: "operationRemove" })),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.remove({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/old.c"],
      force: true,
      keepLocal: true,
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "remove",
      options: {
        version: 1,
        paths: ["src/old.c"],
        force: true,
        keepLocal: true,
      },
    });
    expect(result).toEqual(operationResponse({ kind: "remove", reason: "operationRemove" }));
  });

  it("sends operation/run remove with multiple explicit paths and returns targeted reconcile hints", async () => {
    const response: OperationRunResponse = {
      ...operationResponse({ kind: "remove", path: "src/old.c", reason: "operationRemove" }),
      touchedPaths: ["src/old.c", "src/other.c"],
      summary: { affectedPaths: 2, skippedPaths: 0 },
      reconcile: {
        targets: [
          { path: "src/old.c", depth: "empty", reason: "operationRemove" },
          { path: "src/other.c", depth: "empty", reason: "operationRemove" },
        ],
        requiresFullReconcile: false,
      },
    };
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.remove({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/old.c", "src/other.c"],
      force: true,
      keepLocal: true,
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "remove",
      options: {
        version: 1,
        paths: ["src/old.c", "src/other.c"],
        force: true,
        keepLocal: true,
      },
    });
    expect(result).toEqual(response);
  });

  it("sends operation/run move with explicit source and destination options", async () => {
    const response: OperationRunResponse = {
      ...operationResponse({ kind: "move", path: "src/renamed.c", reason: "operationMove" }),
      touchedPaths: ["src/old.c", "src/renamed.c"],
      summary: { affectedPaths: 2, skippedPaths: 0 },
      reconcile: {
        targets: [
          { path: "src", depth: "immediates", reason: "operationMove" },
        ],
        requiresFullReconcile: false,
      },
    };
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.move({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      sourcePath: "src/old.c",
      destinationPath: "src/renamed.c",
      makeParents: false,
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run cleanup with explicit options and returns the parsed full-reconcile result", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "cleanup",
          path: ".",
          targets: [],
          requiresFullReconcile: true,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

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

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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
    expect(result).toEqual(
      operationResponse({
        kind: "cleanup",
        path: ".",
        targets: [],
        requiresFullReconcile: true,
      }),
    );
  });

  it("sends local operation/run update without a remote envelope", async () => {
    const response = operationResponse({
      kind: "update",
      path: ".",
      revision: 8,
      targets: [],
      requiresFullReconcile: true,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.update({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
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

  it("sends operation/run upgrade and returns the parsed full-reconcile result", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "upgrade",
          path: ".",
          targets: [],
          requiresFullReconcile: true,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.upgrade({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "upgrade",
      options: {
        version: 1,
        path: ".",
      },
    });
    expect(result).toEqual(operationResponse({
      kind: "upgrade",
      path: ".",
      targets: [],
      requiresFullReconcile: true,
    }));
  });

  it("passes cancellation signals to update operation/run requests", async () => {
    const response = operationResponse({
      kind: "update",
      path: ".",
      revision: 8,
      targets: [],
      requiresFullReconcile: true,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);
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

    expect(sender.sendRequest).toHaveBeenCalledWith(
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

  it("sends operation/run update for a selected repository-relative path", async () => {
    const response = operationResponse({
      kind: "update",
      path: "src/main.c",
      revision: 8,
      targets: [],
      requiresFullReconcile: true,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

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

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run update with numeric revision, sparse depth, sticky depth, and externals policy", async () => {
    const response = operationResponse({
      kind: "update",
      path: "src",
      revision: 42,
      targets: [],
      requiresFullReconcile: true,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

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

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run branchCreate and accepts remote-only empty reconcile", async () => {
    const response: OperationRunResponse = {
      ...operationResponse({
        kind: "branchCreate",
        revision: 42,
        targets: [],
        requiresFullReconcile: false,
      }),
      touchedPaths: [],
      summary: { affectedPaths: 0, skippedPaths: 0 },
    };
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.branchCreate(validBranchCreateRequest());

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run switch and requires a full reconcile with resolved revision", async () => {
    const response = operationResponse({
      kind: "switch",
      path: "src",
      revision: 55,
      targets: [],
      requiresFullReconcile: true,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.switch(validSwitchRequest());

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends local file branchCreate without a remote envelope", async () => {
    const response: OperationRunResponse = {
      ...operationResponse({
        kind: "branchCreate",
        revision: 42,
        targets: [],
        requiresFullReconcile: false,
      }),
      touchedPaths: [],
      summary: { affectedPaths: 0, skippedPaths: 0 },
    };
    const sender: JsonRpcSender = { sendRequest: vi.fn().mockResolvedValue(response) };
    const remoteRequest = validBranchCreateRequest();
    const request = {
      ...remoteRequest,
      sourceUrl: "file:///repo/trunk",
      destinationUrl: "file:///repo/branches/feature",
    };
    const { remote: _remote, ...localRequest } = request;
    void _remote;

    await new OperationRunRpcClient(sender).branchCreate(localRequest);

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: localRequest.repositoryId,
      epoch: localRequest.epoch,
      kind: "branchCreate",
      options: {
        version: 1,
        sourceUrl: localRequest.sourceUrl,
        destinationUrl: localRequest.destinationUrl,
        revision: localRequest.revision,
        message: localRequest.message,
        makeParents: localRequest.makeParents,
        ignoreExternals: localRequest.ignoreExternals,
      },
    });
  });

  it("rejects direct svn branchCreate and switch requests without remote", async () => {
    const sender: JsonRpcSender = { sendRequest: vi.fn().mockResolvedValue({}) };
    const client = new OperationRunRpcClient(sender);
    const { remote: branchRemote, ...branchRequest } = validBranchCreateRequest();
    const { remote: switchRemote, ...switchRequest } = validSwitchRequest();
    void branchRemote;
    void switchRemote;

    await expect(client.branchCreate(branchRequest)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      safeArgs: { field: "remote" },
    });
    await expect(client.switch(switchRequest)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      safeArgs: { field: "remote" },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("sends operation/run relocate and requires a full reconcile", async () => {
    const response = operationResponse({
      kind: "relocate",
      path: ".",
      revision: null,
      targets: [],
      requiresFullReconcile: true,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.relocate(validRelocateRequest());

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run merge range and requires a full reconcile", async () => {
    const response = operationResponse({
      kind: "merge",
      path: ".",
      targets: [],
      requiresFullReconcile: true,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.merge(validMergeRequest());

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "merge",
      options: {
        version: 1,
        sourceUrl: "file:///repo/branches/feature",
        targetPath: ".",
        startRevision: 10,
        endRevision: 12,
        depth: "infinity",
        ignoreMergeinfo: false,
        diffIgnoreAncestry: false,
        forceDelete: false,
        recordOnly: false,
        dryRun: false,
        allowMixedRevisions: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("sends operation/run merge range dry run and accepts a targeted reconcile", async () => {
    const response = operationResponse({
      kind: "merge",
      path: ".",
      targets: [{ path: ".", depth: "infinity", reason: "operationMergePreview" }],
      requiresFullReconcile: false,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.merge({
      ...validMergeRequest(),
      dryRun: true,
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "merge",
      options: {
        version: 1,
        sourceUrl: "file:///repo/branches/feature",
        targetPath: ".",
        startRevision: 10,
        endRevision: 12,
        depth: "infinity",
        ignoreMergeinfo: false,
        diffIgnoreAncestry: false,
        forceDelete: false,
        recordOnly: false,
        dryRun: true,
        allowMixedRevisions: false,
      },
    });
    expect(result).toEqual(response);
  });

  it("sends operation/run propertySet with explicit property options", async () => {
    const response = operationResponse({
      kind: "propertySet",
      path: "src",
      reason: "operationPropertySet",
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.propertySet({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
      name: "svn:ignore",
      value: "target\nnode_modules",
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run propertyDelete with explicit property options", async () => {
    const response = operationResponse({
      kind: "propertyDelete",
      path: "src",
      reason: "operationPropertyDelete",
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.propertyDelete({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
      name: "svn:ignore",
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run changelistSet with explicit changelist options", async () => {
    const response = operationResponse({
      kind: "changelistSet",
      path: "src/main.c",
      reason: "operationChangelistSet",
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.changelistSet({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      depth: "empty",
      changelist: "review",
      changelists: [],
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run changelistClear with explicit changelist options", async () => {
    const response = operationResponse({
      kind: "changelistClear",
      path: "src/main.c",
      reason: "operationChangelistClear",
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.changelistClear({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      depth: "empty",
      changelists: ["review"],
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run lock with explicit lock options", async () => {
    const response = operationResponse({
      kind: "lock",
      path: "src/main.c",
      reason: "operationLock",
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.lock({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      comment: null,
      stealLock: false,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run unlock with explicit unlock options", async () => {
    const response = operationResponse({
      kind: "unlock",
      path: "src/main.c",
      reason: "operationUnlock",
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.unlock({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/main.c"],
      breakLock: false,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run commit with explicit single-file options and returns the parsed revision", async () => {
    const response = operationResponse({
      kind: "commit",
      path: "src/main.c",
      reason: "operationCommit",
      revision: 9,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.commit(validCommitRequest());

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
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

  it("sends operation/run commit with multiple explicit file paths and returns targeted reconcile hints", async () => {
    const response: OperationRunResponse = {
      ...operationResponse({
        kind: "commit",
        path: "src/main.c",
        reason: "operationCommit",
        revision: 10,
      }),
      touchedPaths: ["src/main.c", "src/other.c"],
      summary: { affectedPaths: 2, skippedPaths: 0 },
      reconcile: {
        targets: [
          { path: "src/main.c", depth: "empty", reason: "operationCommit" },
          { path: "src/other.c", depth: "empty", reason: "operationCommit" },
        ],
        requiresFullReconcile: false,
      },
    };
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.commit({
      ...validCommitRequest(),
      paths: ["src/main.c", "src/other.c"],
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "commit",
      options: {
        version: 1,
        paths: ["src/main.c", "src/other.c"],
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

  it("sends operation/run commit with a restrictive changelist filter", async () => {
    const response = operationResponse({
      kind: "commit",
      path: "src/review.c",
      reason: "operationCommit",
      revision: 11,
    });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.commit({
      ...validCommitRequest(),
      paths: ["src/review.c"],
      message: "commit review changelist",
      changelists: ["review"],
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      remote: anonymousSvnRemoteEnvelope(),
      kind: "commit",
      options: {
        version: 1,
        paths: ["src/review.c"],
        message: "commit review changelist",
        depth: "empty",
        changelists: ["review"],
        keepLocks: false,
        keepChangelists: false,
        commitAsOperations: false,
        includeFileExternals: false,
        includeDirExternals: false,
      },
    });
    expect(result).toEqual(response);
  });

  it.each<[ResolveOperationChoice]>([
    ["working"],
    ["mineConflict"],
  ])("sends operation/run resolve with explicit %s choice and returns the parsed result", async (choice) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({ kind: "resolve", path: "src/conflicted.txt", reason: "operationResolve" }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    const result = await client.resolve({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      paths: ["src/conflicted.txt"],
      depth: "empty",
      choice,
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("operation/run", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      kind: "resolve",
      options: {
        version: 1,
        paths: ["src/conflicted.txt"],
        depth: "empty",
        choice,
      },
    });
    expect(result).toEqual(
      operationResponse({ kind: "resolve", path: "src/conflicted.txt", reason: "operationResolve" }),
    );
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, paths: ["src/main.c"], depth: "empty", changelists: [], clearChangelists: false, metadataOnly: false, addedKeepLocal: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, paths: ["src/main.c"], depth: "empty", changelists: [], clearChangelists: false, metadataOnly: false, addedKeepLocal: false }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: [], depth: "empty", changelists: [], clearChangelists: false, metadataOnly: false, addedKeepLocal: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["../main.c"], depth: "empty", changelists: [], clearChangelists: false, metadataOnly: false, addedKeepLocal: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src\\main.c"], depth: "empty", changelists: [], clearChangelists: false, metadataOnly: false, addedKeepLocal: false }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "unknown", changelists: [], clearChangelists: false, metadataOnly: false, addedKeepLocal: false }],
    ["changelists.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "empty", changelists: [""], clearChangelists: false, metadataOnly: false, addedKeepLocal: false }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "empty", changelists: [], clearChangelists: false, metadataOnly: false, addedKeepLocal: false, extra: true }],
  ])("fails fast on invalid revert request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse()),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.revert(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, paths: ["src/main.c"], depth: "empty", changelist: "review", changelists: [] }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, paths: ["src/main.c"], depth: "empty", changelist: "review", changelists: [] }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: [], depth: "empty", changelist: "review", changelists: [] }],
    ["paths.1", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c", "src/main.c"], depth: "empty", changelist: "review", changelists: [] }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src\\main.c"], depth: "empty", changelist: "review", changelists: [] }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "workingCopy", changelist: "review", changelists: [] }],
    ["changelist", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "empty", changelist: "", changelists: [] }],
    ["changelist", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "empty", changelist: "bad\nname", changelists: [] }],
    ["changelists.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "empty", changelist: "review", changelists: [""] }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "empty", changelist: "review", changelists: [], extra: true }],
  ])("fails fast on invalid changelistSet request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse({ kind: "changelistSet", reason: "operationChangelistSet" })),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.changelistSet(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, paths: ["src/main.c"], depth: "empty", changelists: [] }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, paths: ["src/main.c"], depth: "empty", changelists: [] }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: [], depth: "empty", changelists: [] }],
    ["paths.1", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c", "src/main.c"], depth: "empty", changelists: [] }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src\\main.c"], depth: "empty", changelists: [] }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "workingCopy", changelists: [] }],
    ["changelists.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "empty", changelists: ["bad\rname"] }],
    ["changelist", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], depth: "empty", changelists: [], changelist: "review" }],
  ])("fails fast on invalid changelistClear request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse({ kind: "changelistClear", reason: "operationChangelistClear" })),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.changelistClear(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, paths: ["src/main.c"], comment: null, stealLock: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, paths: ["src/main.c"], comment: null, stealLock: false }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: [], comment: null, stealLock: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["."], comment: null, stealLock: false }],
    ["paths.1", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c", "src/main.c"], comment: null, stealLock: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src\\main.c"], comment: null, stealLock: false }],
    ["comment", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], comment: "", stealLock: false }],
    ["comment", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], comment: "bad\rcomment", stealLock: false }],
    ["stealLock", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], comment: null, stealLock: "yes" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], comment: null, stealLock: false, extra: true }],
  ].map(([field, request]) => [field, { ...(request as Record<string, unknown>), remote: anonymousSvnRemoteEnvelope() }] as const))(
    "fails fast on invalid lock request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse({ kind: "lock", reason: "operationLock" })),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.lock(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, paths: ["src/main.c"], breakLock: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, paths: ["src/main.c"], breakLock: false }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: [], breakLock: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["."], breakLock: false }],
    ["paths.1", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c", "src/main.c"], breakLock: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src\\main.c"], breakLock: false }],
    ["breakLock", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], breakLock: "yes" }],
    ["stealLock", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], breakLock: false, stealLock: false }],
  ].map(([field, request]) => [field, { ...(request as Record<string, unknown>), remote: anonymousSvnRemoteEnvelope() }] as const))(
    "fails fast on invalid unlock request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse({ kind: "unlock", reason: "operationUnlock" })),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.unlock(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, paths: ["scratch.txt"], depth: "empty", force: false, noIgnore: false, noAutoprops: false, addParents: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, paths: ["scratch.txt"], depth: "empty", force: false, noIgnore: false, noAutoprops: false, addParents: false }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: [], depth: "empty", force: false, noIgnore: false, noAutoprops: false, addParents: false }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["scratch-a.txt", "scratch-b.txt"], depth: "empty", force: false, noIgnore: false, noAutoprops: false, addParents: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src\\scratch.txt"], depth: "empty", force: false, noIgnore: false, noAutoprops: false, addParents: false }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["scratch.txt"], depth: "unknown", force: false, noIgnore: false, noAutoprops: false, addParents: false }],
    ["force", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["scratch.txt"], depth: "empty", force: "yes", noIgnore: false, noAutoprops: false, addParents: false }],
    ["noIgnore", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["scratch.txt"], depth: "empty", force: false, noAutoprops: false, addParents: false }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["scratch.txt"], depth: "empty", force: false, noIgnore: false, noAutoprops: false, addParents: false, extra: true }],
  ])("fails fast on invalid add request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse({ kind: "add", reason: "operationAdd" })),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.add(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, paths: ["src/old.c"], force: false, keepLocal: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, paths: ["src/old.c"], force: false, keepLocal: false }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: [], force: false, keepLocal: false }],
    ["paths.1", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/old.c", "src/old.c"], force: false, keepLocal: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src\\old.c"], force: false, keepLocal: false }],
    ["force", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/old.c"], force: "yes", keepLocal: false }],
    ["keepLocal", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/old.c"], force: false }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/old.c"], force: false, keepLocal: false, extra: true }],
  ])("fails fast on invalid remove request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse({ kind: "remove", reason: "operationRemove" })),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.remove(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, sourcePath: "src/old.c", destinationPath: "src/new.c", makeParents: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, sourcePath: "src/old.c", destinationPath: "src/new.c", makeParents: false }],
    ["sourcePath", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourcePath: ".", destinationPath: "src/new.c", makeParents: false }],
    ["sourcePath", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourcePath: "src\\old.c", destinationPath: "src/new.c", makeParents: false }],
    ["destinationPath", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourcePath: "src/old.c", destinationPath: "../new.c", makeParents: false }],
    ["destinationPath", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourcePath: "src/old.c", destinationPath: "src\\new.c", makeParents: false }],
    ["destinationPath", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourcePath: "src/old.c", destinationPath: "src/old.c", makeParents: false }],
    ["makeParents", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourcePath: "src/old.c", destinationPath: "src/new.c" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourcePath: "src/old.c", destinationPath: "src/new.c", makeParents: false, extra: true }],
  ])("fails fast on invalid move request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(operationResponse({ kind: "move", reason: "operationMove" })),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.move(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, path: ".", breakLocks: true, fixRecordedTimestamps: false, clearDavCache: false, vacuumPristines: false, includeExternals: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, path: ".", breakLocks: true, fixRecordedTimestamps: false, clearDavCache: false, vacuumPristines: false, includeExternals: false }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", breakLocks: true, fixRecordedTimestamps: false, clearDavCache: false, vacuumPristines: false, includeExternals: false }],
    ["breakLocks", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", fixRecordedTimestamps: false, clearDavCache: false, vacuumPristines: false, includeExternals: false }],
    ["fixRecordedTimestamps", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", breakLocks: true, fixRecordedTimestamps: "yes", clearDavCache: false, vacuumPristines: false, includeExternals: false }],
    ["clearDavCache", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", breakLocks: true, fixRecordedTimestamps: false, vacuumPristines: false, includeExternals: false }],
    ["vacuumPristines", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", breakLocks: true, fixRecordedTimestamps: false, clearDavCache: false, includeExternals: false }],
    ["includeExternals", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", breakLocks: true, fixRecordedTimestamps: false, clearDavCache: false, vacuumPristines: false, includeExternals: "no" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", breakLocks: true, fixRecordedTimestamps: false, clearDavCache: false, vacuumPristines: false, includeExternals: false, extra: true }],
  ])("fails fast on invalid cleanup request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "cleanup",
          path: ".",
          targets: [],
          requiresFullReconcile: true,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.cleanup(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, path: "." }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, path: "." }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", extra: true }],
  ])("fails fast on invalid upgrade request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "upgrade",
          path: ".",
          targets: [],
          requiresFullReconcile: true,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.upgrade(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, path: ".", revision: "head", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, path: ".", revision: "head", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "../src", revision: "head", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "", revision: "head", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "/src/main.c", revision: "head", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "C:/wc/src/main.c", revision: "head", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src\\main.c", revision: "head", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["revision", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", revision: "5", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["revision", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", revision: "r5", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["revision", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", revision: -1, depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["revision", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", revision: 2147483648, depth: "workingCopy", depthIsSticky: false, ignoreExternals: true }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", revision: "head", depth: "unknown", depthIsSticky: false, ignoreExternals: true }],
    ["depthIsSticky", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", revision: "head", depth: "workingCopy", depthIsSticky: true, ignoreExternals: true }],
    ["depthIsSticky", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", revision: "head", depth: "files", depthIsSticky: "yes", ignoreExternals: true }],
    ["ignoreExternals", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", revision: "head", depth: "workingCopy", depthIsSticky: false, ignoreExternals: "no" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: ".", revision: "head", depth: "workingCopy", depthIsSticky: false, ignoreExternals: true, extra: true }],
  ].map(([field, request]) => [field, { ...(request as Record<string, unknown>), remote: anonymousSvnRemoteEnvelope() }] as const))(
    "fails fast on invalid update request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "update",
          path: ".",
          revision: 8,
          targets: [],
          requiresFullReconcile: true,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.update(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, sourceUrl: "file:///repo/trunk", destinationUrl: "file:///repo/branches/feature", revision: "head", message: "Create branch", makeParents: false, ignoreExternals: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, sourceUrl: "file:///repo/trunk", destinationUrl: "file:///repo/branches/feature", revision: "head", message: "Create branch", makeParents: false, ignoreExternals: false }],
    ["sourceUrl", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourceUrl: "", destinationUrl: "file:///repo/branches/feature", revision: "head", message: "Create branch", makeParents: false, ignoreExternals: false }],
    ["sourceUrl", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourceUrl: "file:///repo/trunk\nbad", destinationUrl: "file:///repo/branches/feature", revision: "head", message: "Create branch", makeParents: false, ignoreExternals: false }],
    ["destinationUrl", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourceUrl: "file:///repo/trunk", destinationUrl: "file:///repo/trunk", revision: "head", message: "Create branch", makeParents: false, ignoreExternals: false }],
    ["revision", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourceUrl: "file:///repo/trunk", destinationUrl: "file:///repo/branches/feature", revision: "r5", message: "Create branch", makeParents: false, ignoreExternals: false }],
    ["message", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourceUrl: "file:///repo/trunk", destinationUrl: "file:///repo/branches/feature", revision: "head", message: "bad\rmessage", makeParents: false, ignoreExternals: false }],
    ["makeParents", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourceUrl: "file:///repo/trunk", destinationUrl: "file:///repo/branches/feature", revision: "head", message: "Create branch", ignoreExternals: false }],
    ["ignoreExternals", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourceUrl: "file:///repo/trunk", destinationUrl: "file:///repo/branches/feature", revision: "head", message: "Create branch", makeParents: false }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, sourceUrl: "file:///repo/trunk", destinationUrl: "file:///repo/branches/feature", revision: "head", message: "Create branch", makeParents: false, ignoreExternals: false, extra: true }],
  ].map(([field, request]) => [field, {
    ...(request as Record<string, unknown>),
    ...(field === "sourceUrl" ? {} : { sourceUrl: "svn://svn.example.invalid/repo/trunk" }),
    ...(field === "destinationUrl" ? {} : { destinationUrl: "svn://svn.example.invalid/repo/branches/feature" }),
    remote: anonymousSvnRemoteEnvelope(),
  }] as const))(
    "fails fast on invalid branchCreate request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "branchCreate",
          revision: 42,
          targets: [],
          requiresFullReconcile: false,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.branchCreate(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, path: "src", url: "file:///repo/branches/feature/src", revision: 55, depth: "infinity", depthIsSticky: true, ignoreExternals: true, ignoreAncestry: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, path: "src", url: "file:///repo/branches/feature/src", revision: 55, depth: "infinity", depthIsSticky: true, ignoreExternals: true, ignoreAncestry: false }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "../src", url: "file:///repo/branches/feature/src", revision: 55, depth: "infinity", depthIsSticky: true, ignoreExternals: true, ignoreAncestry: false }],
    ["url", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", url: "file:///repo/branches/feature/src\nbad", revision: 55, depth: "infinity", depthIsSticky: true, ignoreExternals: true, ignoreAncestry: false }],
    ["revision", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", url: "file:///repo/branches/feature/src", revision: "r55", depth: "infinity", depthIsSticky: true, ignoreExternals: true, ignoreAncestry: false }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", url: "file:///repo/branches/feature/src", revision: 55, depth: "unknown", depthIsSticky: true, ignoreExternals: true, ignoreAncestry: false }],
    ["depthIsSticky", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", url: "file:///repo/branches/feature/src", revision: "head", depth: "workingCopy", depthIsSticky: true, ignoreExternals: true, ignoreAncestry: false }],
    ["ignoreExternals", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", url: "file:///repo/branches/feature/src", revision: 55, depth: "infinity", depthIsSticky: true, ignoreExternals: "yes", ignoreAncestry: false }],
    ["ignoreAncestry", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", url: "file:///repo/branches/feature/src", revision: 55, depth: "infinity", depthIsSticky: true, ignoreExternals: true }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", url: "file:///repo/branches/feature/src", revision: 55, depth: "infinity", depthIsSticky: true, ignoreExternals: true, ignoreAncestry: false, extra: true }],
  ].map(([field, request]) => [field, {
    ...(request as Record<string, unknown>),
    ...(field === "url" ? {} : { url: "svn://svn.example.invalid/repo/branches/feature/src" }),
    remote: anonymousSvnRemoteEnvelope(),
  }] as const))(
    "fails fast on invalid switch request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "switch",
          path: "src",
          revision: 55,
          targets: [],
          requiresFullReconcile: true,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.switch(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, fromUrl: "file:///repo", toUrl: "https://svn.example.invalid/repo", ignoreExternals: true }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, fromUrl: "file:///repo", toUrl: "https://svn.example.invalid/repo", ignoreExternals: true }],
    ["fromUrl", { repositoryId: "repo-uuid:C:/wc", epoch: 7, fromUrl: "", toUrl: "https://svn.example.invalid/repo", ignoreExternals: true }],
    ["fromUrl", { repositoryId: "repo-uuid:C:/wc", epoch: 7, fromUrl: "file:///repo\nbad", toUrl: "https://svn.example.invalid/repo", ignoreExternals: true }],
    ["toUrl", { repositoryId: "repo-uuid:C:/wc", epoch: 7, fromUrl: "file:///repo", toUrl: "file:///repo", ignoreExternals: true }],
    ["ignoreExternals", { repositoryId: "repo-uuid:C:/wc", epoch: 7, fromUrl: "file:///repo", toUrl: "https://svn.example.invalid/repo" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, fromUrl: "file:///repo", toUrl: "https://svn.example.invalid/repo", ignoreExternals: true, extra: true }],
  ])("fails fast on invalid relocate request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "relocate",
          targets: [],
          requiresFullReconcile: true,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.relocate(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, path: "src", name: "svn:ignore", value: "target" }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, path: "src", name: "svn:ignore", value: "target" }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "../src", name: "svn:ignore", value: "target" }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src\\generated", name: "svn:ignore", value: "target" }],
    ["name", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", name: "", value: "target" }],
    ["name", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", name: "svn:\nignore", value: "target" }],
    ["name", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", name: "svn:ignore!", value: "target" }],
    ["value", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", name: "svn:ignore", value: "bad\rvalue" }],
    ["value", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", name: "svn:ignore", value: "bad\0value" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", name: "svn:ignore", value: "target", extra: true }],
  ])("fails fast on invalid propertySet request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "propertySet",
          path: "src",
          reason: "operationPropertySet",
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.propertySet(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, path: "src", name: "svn:ignore" }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, path: "src", name: "svn:ignore" }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "../src", name: "svn:ignore" }],
    ["name", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", name: "svn:\nignore" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", name: "svn:ignore", extra: true }],
  ])("fails fast on invalid propertyDelete request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "propertyDelete",
          path: "src",
          reason: "operationPropertyDelete",
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.propertyDelete(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: [], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["paths.1", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c", "src/main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["."], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src\\main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["message", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["message", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "line one\r\nline two", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["message", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "bad\0message", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "files", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["changelists.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: ["bad\nname"], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["changelists.1", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: ["feature", "feature"], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["keepLocks", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: true, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["keepChangelists", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: true, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false }],
    ["commitAsOperations", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: true, includeFileExternals: false, includeDirExternals: false }],
    ["includeFileExternals", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: true, includeDirExternals: false }],
    ["includeDirExternals", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: true }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/main.c"], message: "commit tracked file", depth: "empty", changelists: [], keepLocks: false, keepChangelists: false, commitAsOperations: false, includeFileExternals: false, includeDirExternals: false, extra: true }],
  ].map(([field, request]) => [field, { ...(request as Record<string, unknown>), remote: anonymousSvnRemoteEnvelope() }] as const))(
    "fails fast on invalid commit request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "commit",
          path: "src/main.c",
          reason: "operationCommit",
          revision: 9,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.commit(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, paths: ["src/conflicted.txt"], depth: "empty", choice: "working" }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, paths: ["src/conflicted.txt"], depth: "empty", choice: "working" }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: [], depth: "empty", choice: "working" }],
    ["paths", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["one.txt", "two.txt"], depth: "empty", choice: "working" }],
    ["paths.0", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src\\conflicted.txt"], depth: "empty", choice: "working" }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/conflicted.txt"], depth: "unknown", choice: "working" }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/conflicted.txt"], depth: "files", choice: "working" }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/conflicted.txt"], depth: "immediates", choice: "working" }],
    ["depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/conflicted.txt"], depth: "infinity", choice: "working" }],
    ["choice", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/conflicted.txt"], depth: "empty", choice: "merged" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, paths: ["src/conflicted.txt"], depth: "empty", choice: "working", extra: true }],
  ])("fails fast on invalid resolve request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({ kind: "resolve", path: "src/conflicted.txt", reason: "operationResolve" }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.resolve(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_REQUEST_INVALID",
      category: "input",
      messageKey: "error.operation.runRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", (response: OperationRunResponse) => (response.repositoryId = "other:C:/wc")],
    ["epoch", (response: OperationRunResponse) => (response.epoch = 8)],
    ["kind", (response: OperationRunResponse) => (response.kind = "commit")],
    ["operationId", (response: OperationRunResponse) => (response.operationId = "")],
    ["touchedPaths.0", (response: OperationRunResponse) => (response.touchedPaths = ["../main.c"])],
    ["touchedPaths.0", (response: OperationRunResponse) => (response.touchedPaths = ["src\\main.c"])],
    ["revision", (response: OperationRunResponse) => (response.revision = 1.5 as never)],
    ["summary.affectedPaths", (response: OperationRunResponse) => (response.summary.affectedPaths = -1)],
    ["warnings.0.args", (response: OperationRunResponse) => (response.warnings[0].args = "unsafe" as never)],
    ["reconcile.targets", (response: OperationRunResponse) => (response.reconcile.targets = [])],
    [
      "reconcile.targets.0.depth",
      (response: OperationRunResponse) => ((response.reconcile.targets[0] as { depth: string }).depth = "unknown"),
    ],
    ["reconcile.targets.0.path", (response: OperationRunResponse) => (response.reconcile.targets[0].path = "src\\main.c")],
  ])("rejects inconsistent operation response field: %s", async (field, mutate) => {
    const response = operationResponse();
    mutate(response);
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.revert(validRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field },
    });
  });

  it("rejects cleanup responses that do not require a full reconcile", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "cleanup",
          path: ".",
          reason: "operationCleanup",
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(
      client.cleanup({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: ".",
        breakLocks: true,
        fixRecordedTimestamps: false,
        clearDavCache: false,
        vacuumPristines: false,
        includeExternals: false,
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "reconcile.requiresFullReconcile" },
    });
  });

  it("rejects upgrade responses that do not require a full reconcile", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "upgrade",
          path: ".",
          reason: "operationUpgrade",
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(
      client.upgrade({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: ".",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "reconcile.requiresFullReconcile" },
    });
  });

  it("rejects update responses without a full reconcile", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "update",
          path: ".",
          reason: "operationUpdate",
          revision: 8,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.update(validUpdateRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "reconcile.requiresFullReconcile" },
    });
  });

  it("rejects update responses without a resolved revision", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "update",
          path: ".",
          revision: null,
          targets: [],
          requiresFullReconcile: true,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.update(validUpdateRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "revision" },
    });
  });

  it("rejects branchCreate responses without a committed revision", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "branchCreate",
          revision: null,
          targets: [],
          requiresFullReconcile: false,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.branchCreate(validBranchCreateRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "revision" },
    });
  });

  it("rejects switch responses without a full reconcile", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "switch",
          path: "src",
          revision: 55,
          reason: "operationSwitch",
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.switch(validSwitchRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "reconcile.requiresFullReconcile" },
    });
  });

  it("rejects switch responses without a resolved revision", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "switch",
          path: "src",
          revision: null,
          targets: [],
          requiresFullReconcile: true,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.switch(validSwitchRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "revision" },
    });
  });

  it("rejects relocate responses without a full reconcile", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "relocate",
          path: ".",
          reason: "operationRelocate",
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.relocate(validRelocateRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "reconcile.requiresFullReconcile" },
    });
  });

  it("rejects commit responses without a resolved revision", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(
        operationResponse({
          kind: "commit",
          path: "src/main.c",
          reason: "operationCommit",
          revision: null,
        }),
      ),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.commit(validCommitRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "revision" },
    });
  });

  it("rejects extra operation response fields", async () => {
    const response = operationResponse();
    addWireField(response.reconcile, "extra", true);
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.revert(validRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_RUN_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.operation.runResponseInvalid",
      safeArgs: { field: "reconcile.extra" },
    });
  });

  it("propagates backend errors without replacing their structured payload", async () => {
    const backendError = new Error("backend failed");
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockRejectedValue(backendError),
    };
    const client = new OperationRunRpcClient(sender);

    await expect(client.revert(validRequest())).rejects.toBe(backendError);
  });
});

function validRequest() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    paths: ["src/main.c"],
    depth: "empty" as const,
    changelists: [],
    clearChangelists: false,
    metadataOnly: false,
    addedKeepLocal: false,
  };
}

function validUpdateRequest() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: "." as const,
    revision: "head" as const,
    depth: "workingCopy" as const,
    depthIsSticky: false as const,
    ignoreExternals: true as const,
    remote: anonymousSvnRemoteEnvelope(),
  };
}

function validMergeRequest() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    sourceUrl: "file:///repo/branches/feature",
    targetPath: "." as const,
    startRevision: 10,
    endRevision: 12,
    depth: "infinity" as const,
    ignoreMergeinfo: false,
    diffIgnoreAncestry: false,
    forceDelete: false,
    recordOnly: false,
    dryRun: false,
    allowMixedRevisions: false,
  };
}

function validBranchCreateRequest() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    sourceUrl: "svn://svn.example.invalid/repo/trunk",
    destinationUrl: "svn://svn.example.invalid/repo/branches/feature",
    revision: "head" as const,
    message: "Create feature branch",
    makeParents: true,
    ignoreExternals: false,
    remote: anonymousSvnRemoteEnvelope(),
  };
}

function validSwitchRequest() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: "src",
    url: "svn://svn.example.invalid/repo/branches/feature/src",
    revision: 55,
    depth: "infinity" as const,
    depthIsSticky: true,
    ignoreExternals: true,
    ignoreAncestry: false,
    remote: anonymousSvnRemoteEnvelope(),
  };
}

function validRelocateRequest() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    fromUrl: "file:///repo",
    toUrl: "https://svn.example.invalid/repo",
    ignoreExternals: true,
  };
}

function validCommitRequest() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    paths: ["src/main.c"],
    message: "commit tracked file",
    depth: "empty" as const,
    changelists: [],
    keepLocks: false as const,
    keepChangelists: false as const,
    commitAsOperations: false as const,
    includeFileExternals: false as const,
    includeDirExternals: false as const,
    remote: anonymousSvnRemoteEnvelope(),
  };
}

function operationResponse(
  options: {
    kind?: string;
    path?: string;
    reason?: string;
    revision?: number | null;
    targets?: OperationRunResponse["reconcile"]["targets"];
    requiresFullReconcile?: boolean;
  } = {},
): OperationRunResponse {
  const kind = options.kind ?? "revert";
  const path =
    options.path ??
    (kind === "add"
      ? "scratch.txt"
      : kind === "remove"
        ? "src/old.c"
        : kind === "resolve"
          ? "src/conflicted.txt"
          : kind === "update"
            ? "."
          : "src/main.c");
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
    warnings: [
      {
        code: "SVN_OPERATION_PATH_SKIPPED",
        messageKey: "warning.operation.pathSkipped",
        args: { path: "scratch.txt" },
      },
    ],
    reconcile: {
      targets: options.targets ?? [{ path, depth: "empty", reason: options.reason ?? "operationRevert" }],
      requiresFullReconcile: options.requiresFullReconcile ?? false,
    },
  };
}

function addWireField(target: object, key: string, value: unknown): void {
  (target as Record<string, unknown>)[key] = value;
}

expect(OperationRunResponseError).toBeDefined();

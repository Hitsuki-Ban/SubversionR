import { describe, expect, it, vi } from "vitest";
import {
  RepositoryCheckoutResponseError,
  RepositoryCheckoutRpcClient,
  type RepositoryCheckoutResponse,
} from "../src/repository/repositoryCheckoutRpcClient";
import type { JsonRpcSender } from "../src/status/types";
import { anonymousSvnRemoteEnvelope } from "./remoteOperationEnvelopeFixture";

describe("RepositoryCheckoutRpcClient", () => {
  it("sends local file checkout without a remote envelope", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(checkoutResponse()),
    };
    const client = new RepositoryCheckoutRpcClient(sender);
    const request = {
      url: "file:///C:/fixtures/project/trunk",
      targetPath: "C:/workspace/project",
      revision: "head" as const,
      depth: "infinity" as const,
      ignoreExternals: false,
    };

    await client.checkout(request);

    expect(sender.sendRequest).toHaveBeenCalledWith("repository/checkout", request);
  });

  it("rejects remote envelopes on local file checkout", async () => {
    const sender: JsonRpcSender = { sendRequest: vi.fn().mockResolvedValue(checkoutResponse()) };
    const client = new RepositoryCheckoutRpcClient(sender);

    await expect(client.checkout({
      url: "file:///C:/fixtures/project/trunk",
      targetPath: "C:/workspace/project",
      revision: "head",
      depth: "infinity",
      ignoreExternals: false,
      remote: anonymousSvnRemoteEnvelope(),
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_CHECKOUT_REQUEST_INVALID",
      safeArgs: { field: "remote" },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("rejects svn checkout when URL authority differs from the remote envelope", async () => {
    const sender: JsonRpcSender = { sendRequest: vi.fn().mockResolvedValue(checkoutResponse()) };
    const client = new RepositoryCheckoutRpcClient(sender);

    await expect(client.checkout({
      url: "svn://other.example.invalid/project/trunk",
      targetPath: "C:/workspace/project",
      revision: "head",
      depth: "infinity",
      ignoreExternals: false,
      remote: anonymousSvnRemoteEnvelope(),
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_CHECKOUT_REQUEST_INVALID",
      safeArgs: { field: "url" },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("sends repository/checkout with explicit checkout options", async () => {
    const response = checkoutResponse();
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new RepositoryCheckoutRpcClient(sender);

    const result = await client.checkout({
      url: "svn://svn.example.invalid/project/trunk",
      targetPath: "C:/workspace/project",
      revision: 42,
      depth: "files",
      ignoreExternals: false,
      remote: anonymousSvnRemoteEnvelope(),
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("repository/checkout", {
      url: "svn://svn.example.invalid/project/trunk",
      targetPath: "C:/workspace/project",
      revision: 42,
      depth: "files",
      ignoreExternals: false,
      remote: anonymousSvnRemoteEnvelope(),
    });
    expect(result).toEqual(response);
  });

  it("passes cancellation signals to repository/checkout", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(checkoutResponse()),
    };
    const client = new RepositoryCheckoutRpcClient(sender);
    const cancellation = new AbortController();

    await client.checkout(
      {
        url: "svn://svn.example.invalid/project/trunk",
        targetPath: "C:/workspace/project",
        revision: "head",
        depth: "infinity",
        ignoreExternals: true,
        remote: anonymousSvnRemoteEnvelope(),
      },
      { signal: cancellation.signal },
    );

    expect(sender.sendRequest).toHaveBeenCalledWith(
      "repository/checkout",
      {
        url: "svn://svn.example.invalid/project/trunk",
        targetPath: "C:/workspace/project",
        revision: "head",
        depth: "infinity",
        ignoreExternals: true,
        remote: anonymousSvnRemoteEnvelope(),
      },
      { signal: cancellation.signal },
    );
  });

  it.each([
    ["url", { url: "", targetPath: "C:/workspace/project", revision: "head", depth: "infinity", ignoreExternals: true, remote: anonymousSvnRemoteEnvelope() }],
    ["targetPath", { url: "svn://svn.example.invalid/project/trunk", targetPath: "project", revision: "head", depth: "infinity", ignoreExternals: true, remote: anonymousSvnRemoteEnvelope() }],
    ["revision", { url: "svn://svn.example.invalid/project/trunk", targetPath: "C:/workspace/project", revision: -1, depth: "infinity", ignoreExternals: true, remote: anonymousSvnRemoteEnvelope() }],
    ["depth", { url: "svn://svn.example.invalid/project/trunk", targetPath: "C:/workspace/project", revision: "head", depth: "workingCopy", ignoreExternals: true, remote: anonymousSvnRemoteEnvelope() }],
    ["ignoreExternals", { url: "svn://svn.example.invalid/project/trunk", targetPath: "C:/workspace/project", revision: "head", depth: "infinity", remote: anonymousSvnRemoteEnvelope() }],
    ["remote", { url: "svn://svn.example.invalid/project/trunk", targetPath: "C:/workspace/project", revision: "head", depth: "infinity", ignoreExternals: true }],
    ["extra", { url: "svn://svn.example.invalid/project/trunk", targetPath: "C:/workspace/project", revision: "head", depth: "infinity", ignoreExternals: true, remote: anonymousSvnRemoteEnvelope(), extra: true }],
  ])("fails fast on invalid request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(checkoutResponse()),
    };
    const client = new RepositoryCheckoutRpcClient(sender);

    await expect(client.checkout(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_CHECKOUT_REQUEST_INVALID",
      category: "input",
      messageKey: "error.repository.checkoutRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["workingCopyPath", (response: RepositoryCheckoutResponse) => (response.workingCopyPath = "project")],
    ["revision", (response: RepositoryCheckoutResponse) => (response.revision = -1)],
  ])("rejects invalid response field: %s", async (field, mutate) => {
    const response = checkoutResponse();
    mutate(response);
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new RepositoryCheckoutRpcClient(sender);

    await expect(
      client.checkout({
        url: "svn://svn.example.invalid/project/trunk",
        targetPath: "C:/workspace/project",
        revision: "head",
        depth: "infinity",
        ignoreExternals: true,
        remote: anonymousSvnRemoteEnvelope(),
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REPOSITORY_CHECKOUT_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.repository.checkoutResponseInvalid",
      safeArgs: { field },
    });
  });

  it("propagates backend errors without replacing their structured payload", async () => {
    const backendError = new Error("backend failed");
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockRejectedValue(backendError),
    };
    const client = new RepositoryCheckoutRpcClient(sender);

    await expect(
      client.checkout({
        url: "svn://svn.example.invalid/project/trunk",
        targetPath: "C:/workspace/project",
        revision: "head",
        depth: "infinity",
        ignoreExternals: true,
        remote: anonymousSvnRemoteEnvelope(),
      }),
    ).rejects.toBe(backendError);
  });
});

function checkoutResponse(): RepositoryCheckoutResponse {
  return {
    workingCopyPath: "C:/workspace/project",
    revision: 42,
  };
}

expect(RepositoryCheckoutResponseError).toBeDefined();

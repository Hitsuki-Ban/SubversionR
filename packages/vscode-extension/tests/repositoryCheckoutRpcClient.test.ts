import { describe, expect, it, vi } from "vitest";
import {
  RepositoryCheckoutResponseError,
  RepositoryCheckoutRpcClient,
  type RepositoryCheckoutResponse,
} from "../src/repository/repositoryCheckoutRpcClient";
import type { JsonRpcSender } from "../src/status/types";

describe("RepositoryCheckoutRpcClient", () => {
  it("sends repository/checkout with explicit checkout options", async () => {
    const response = checkoutResponse();
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new RepositoryCheckoutRpcClient(sender);

    const result = await client.checkout({
      url: "https://svn.example.invalid/project/trunk",
      targetPath: "C:/workspace/project",
      revision: 42,
      depth: "files",
      ignoreExternals: false,
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("repository/checkout", {
      url: "https://svn.example.invalid/project/trunk",
      targetPath: "C:/workspace/project",
      revision: 42,
      depth: "files",
      ignoreExternals: false,
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
        url: "https://svn.example.invalid/project/trunk",
        targetPath: "C:/workspace/project",
        revision: "head",
        depth: "infinity",
        ignoreExternals: true,
      },
      { signal: cancellation.signal },
    );

    expect(sender.sendRequest).toHaveBeenCalledWith(
      "repository/checkout",
      {
        url: "https://svn.example.invalid/project/trunk",
        targetPath: "C:/workspace/project",
        revision: "head",
        depth: "infinity",
        ignoreExternals: true,
      },
      { signal: cancellation.signal },
    );
  });

  it.each([
    ["url", { url: "", targetPath: "C:/workspace/project", revision: "head", depth: "infinity", ignoreExternals: true }],
    ["targetPath", { url: "https://svn.example.invalid/project/trunk", targetPath: "project", revision: "head", depth: "infinity", ignoreExternals: true }],
    ["revision", { url: "https://svn.example.invalid/project/trunk", targetPath: "C:/workspace/project", revision: -1, depth: "infinity", ignoreExternals: true }],
    ["depth", { url: "https://svn.example.invalid/project/trunk", targetPath: "C:/workspace/project", revision: "head", depth: "workingCopy", ignoreExternals: true }],
    ["ignoreExternals", { url: "https://svn.example.invalid/project/trunk", targetPath: "C:/workspace/project", revision: "head", depth: "infinity" }],
    ["extra", { url: "https://svn.example.invalid/project/trunk", targetPath: "C:/workspace/project", revision: "head", depth: "infinity", ignoreExternals: true, extra: true }],
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
        url: "https://svn.example.invalid/project/trunk",
        targetPath: "C:/workspace/project",
        revision: "head",
        depth: "infinity",
        ignoreExternals: true,
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
        url: "https://svn.example.invalid/project/trunk",
        targetPath: "C:/workspace/project",
        revision: "head",
        depth: "infinity",
        ignoreExternals: true,
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

import { describe, expect, it, vi } from "vitest";
import {
  PropertiesListResponseError,
  PropertiesListRpcClient,
  type PropertiesListResponse,
} from "../src/properties/propertiesListRpcClient";
import type { JsonRpcSender } from "../src/status/types";

describe("PropertiesListRpcClient", () => {
  it("sends properties/list with explicit options and returns parsed property entries", async () => {
    const response = propertiesResponse();
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new PropertiesListRpcClient(sender);

    const result = await client.listProperties({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("properties/list", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
    });
    expect(result).toEqual(response);
  });

  it("accepts the working copy root path", async () => {
    const response = propertiesResponse({ path: "." });
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new PropertiesListRpcClient(sender);

    const result = await client.listProperties({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("properties/list", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
    });
    expect(result).toEqual(response);
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, path: "src" }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, path: "src" }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "../src" }],
    ["path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src\\generated" }],
    ["extra", { repositoryId: "repo-uuid:C:/wc", epoch: 7, path: "src", extra: true }],
  ])("fails fast on invalid request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(propertiesResponse()),
    };
    const client = new PropertiesListRpcClient(sender);

    await expect(client.listProperties(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_PROPERTIES_LIST_REQUEST_INVALID",
      category: "input",
      messageKey: "error.properties.listRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", (response: PropertiesListResponse) => (response.repositoryId = "other:C:/wc")],
    ["epoch", (response: PropertiesListResponse) => (response.epoch = 8)],
    ["path", (response: PropertiesListResponse) => (response.path = "other")],
    ["properties.0.name", (response: PropertiesListResponse) => (response.properties[0].name = "svn:\nignore")],
    ["properties.0.value", (response: PropertiesListResponse) => (response.properties[0].value = "bad\rvalue")],
    ["properties.0.valueEncoding", (response: PropertiesListResponse) => (response.properties[0].valueEncoding = "base64" as never)],
    ["source", (response: PropertiesListResponse) => (response.source = "cache" as never)],
  ])("rejects invalid response field: %s", async (field, mutate) => {
    const response = propertiesResponse();
    mutate(response);
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new PropertiesListRpcClient(sender);

    await expect(
      client.listProperties({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_PROPERTIES_LIST_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.properties.listResponseInvalid",
      safeArgs: { field },
    });
  });

  it("rejects extra response fields", async () => {
    const response = propertiesResponse() as PropertiesListResponse & { extra?: boolean };
    response.extra = true;
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new PropertiesListRpcClient(sender);

    await expect(
      client.listProperties({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_PROPERTIES_LIST_RESPONSE_INVALID",
      safeArgs: { field: "extra" },
    });
  });

  it("propagates backend errors without replacing their structured payload", async () => {
    const backendError = new Error("backend failed");
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockRejectedValue(backendError),
    };
    const client = new PropertiesListRpcClient(sender);

    await expect(
      client.listProperties({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src",
      }),
    ).rejects.toBe(backendError);
  });
});

function propertiesResponse(options: { path?: string } = {}): PropertiesListResponse {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: options.path ?? "src",
    properties: [
      {
        name: "svn:ignore",
        value: "target\nnode_modules",
        valueEncoding: "utf8",
      },
    ],
    source: "libsvn-local",
  };
}

expect(PropertiesListResponseError).toBeDefined();

import { describe, expect, it, vi } from "vitest";
import { CheckoutTargetRecoveryRpcClient } from "../src/repository/checkoutTargetRecoveryRpcClient";

const ENTRY = {
  targetPath: "C:\\workspace\\checkout",
  targetSha256: "a".repeat(64),
  originOperationId: "01234567-89ab-4def-8123-456789abcdef",
  state: "blocked" as const,
};

describe("CheckoutTargetRecoveryRpcClient", () => {
  it("lists strictly attributed bounded recovery entries", async () => {
    const sender = {
      sendRequest: vi.fn().mockResolvedValue({ entries: [ENTRY] }),
    };
    await expect(new CheckoutTargetRecoveryRpcClient(sender).list()).resolves.toEqual([ENTRY]);
    expect(sender.sendRequest).toHaveBeenCalledWith("remote/listCheckoutTargetRecoveries", {});
  });

  it("confirms only the exact reviewed disposition contract", async () => {
    const sender = {
      sendRequest: vi.fn().mockResolvedValue({
        released: true,
        targetSha256: ENTRY.targetSha256,
        originOperationId: ENTRY.originOperationId,
      }),
    };
    const request = {
      targetPath: ENTRY.targetPath,
      targetSha256: ENTRY.targetSha256,
      originOperationId: ENTRY.originOperationId,
      confirmation: "reviewedAndResolved" as const,
    };
    await expect(new CheckoutTargetRecoveryRpcClient(sender).confirm(request)).resolves.toEqual({
      released: true,
      targetSha256: ENTRY.targetSha256,
      originOperationId: ENTRY.originOperationId,
    });
    expect(sender.sendRequest).toHaveBeenCalledWith("remote/confirmCheckoutTargetDisposition", request);
  });

  it("rejects unknown fields and mismatched response attribution", async () => {
    const unknown = new CheckoutTargetRecoveryRpcClient({
      sendRequest: vi.fn().mockResolvedValue({ entries: [{ ...ENTRY, extra: true }] }),
    });
    await expect(unknown.list()).rejects.toThrow("SUBVERSIONR_CHECKOUT_TARGET_RECOVERY_RESPONSE_INVALID");

    const mismatched = new CheckoutTargetRecoveryRpcClient({
      sendRequest: vi.fn().mockResolvedValue({
        released: true,
        targetSha256: "b".repeat(64),
        originOperationId: ENTRY.originOperationId,
      }),
    });
    await expect(mismatched.confirm({
      targetPath: ENTRY.targetPath,
      targetSha256: ENTRY.targetSha256,
      originOperationId: ENTRY.originOperationId,
      confirmation: "reviewedAndResolved",
    })).rejects.toThrow("SUBVERSIONR_CHECKOUT_TARGET_RECOVERY_RESPONSE_INVALID");
  });

  it("rejects malformed confirmation input as an invalid request before RPC", async () => {
    const sender = { sendRequest: vi.fn() };
    const client = new CheckoutTargetRecoveryRpcClient(sender);

    await expect(client.confirm({
      ...ENTRY,
      confirmation: "reviewedAndResolved",
      extra: true,
    } as never)).rejects.toThrow("SUBVERSIONR_CHECKOUT_TARGET_RECOVERY_REQUEST_INVALID:request");
    await expect(client.confirm({
      targetPath: "relative-target",
      targetSha256: ENTRY.targetSha256,
      originOperationId: ENTRY.originOperationId,
      confirmation: "reviewedAndResolved",
    })).rejects.toThrow("SUBVERSIONR_CHECKOUT_TARGET_RECOVERY_REQUEST_INVALID:attribution");
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });
});

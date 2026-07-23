import { describe, expect, it } from "vitest";
import {
  REMOTE_PROFILE_SCHEMA,
  RemoteOperationEnvelopeFactory,
  validateAnonymousSvnRemoteOperationEnvelope,
  type AnonymousSvnRemoteOperationInput,
} from "../src/security/remoteAccessProfile";

const INPUT: AnonymousSvnRemoteOperationInput = {
  operationId: "01234567-89ab-4def-8123-456789abcdef",
  intent: "foreground",
  interaction: "allowed",
  timeoutMs: 30_000,
  profile: {
    schema: REMOTE_PROFILE_SCHEMA,
    profileId: "anonymous-svn",
    authority: { scheme: "svn", canonicalHost: "svn.example.invalid", effectivePort: 3690 },
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  },
  expectedOrigin: { scheme: "svn", canonicalHost: "svn.example.invalid", effectivePort: 3690 },
};

describe("RemoteOperationEnvelopeFactory", () => {
  it("builds the exact reviewed anonymous svn envelope only after capability and trust admission", () => {
    const factory = new RemoteOperationEnvelopeFactory({
      remoteSvnAnonymous: true,
      isRemoteSubmissionEnabled: () => true,
      currentRemoteTrustEpoch: () => 7,
    });

    expect(factory.createAnonymousSvn(INPUT)).toEqual({
      version: 1,
      operationId: INPUT.operationId,
      intent: "foreground",
      interaction: "allowed",
      timeoutMs: 30_000,
      workspaceTrust: "trusted",
      trustEpoch: 7,
      profile: INPUT.profile,
      expectedOrigin: INPUT.expectedOrigin,
    });
  });

  it.each([
    [{ remoteSvnAnonymous: false, isRemoteSubmissionEnabled: () => true, currentRemoteTrustEpoch: () => 7 }, "SUBVERSIONR_REMOTE_SVN_ANONYMOUS_CAPABILITY_REQUIRED"],
    [{ remoteSvnAnonymous: true, isRemoteSubmissionEnabled: () => false, currentRemoteTrustEpoch: () => 7 }, "SUBVERSIONR_REMOTE_TRUST_NOT_ACKNOWLEDGED"],
  ] as const)("fails fast when admission is %o", (admission, code) => {
    expect(() => new RemoteOperationEnvelopeFactory(admission).createAnonymousSvn(INPUT)).toThrowError(
      expect.objectContaining({ code }),
    );
  });

  it("reads trust admission and epoch at creation time", () => {
    let trusted = true;
    let trustEpoch = 7;
    const factory = new RemoteOperationEnvelopeFactory({
      remoteSvnAnonymous: true,
      isRemoteSubmissionEnabled: () => trusted,
      currentRemoteTrustEpoch: () => trustEpoch,
    });

    expect(factory.createAnonymousSvn(INPUT).trustEpoch).toBe(7);
    trustEpoch = 8;
    expect(factory.createAnonymousSvn(INPUT).trustEpoch).toBe(8);
    trusted = false;
    expect(() => factory.createAnonymousSvn(INPUT)).toThrowError(
      expect.objectContaining({ code: "SUBVERSIONR_REMOTE_TRUST_NOT_ACKNOWLEDGED" }),
    );
  });

  it.each([
    [{ ...INPUT, expectedOrigin: { ...INPUT.expectedOrigin, scheme: "https" as const } }, "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH"],
    [{ ...INPUT, profile: { ...INPUT.profile, authority: { ...INPUT.profile.authority, scheme: "https" as const }, tls: { trust: "windowsRootsThenBroker" as const } } }, "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH"],
    [{ ...INPUT, profile: { ...INPUT.profile, serverAuth: "cramMd5" as const, serverAccount: { mode: "fixed" as const, username: "alice" } } }, "SUBVERSIONR_REMOTE_SVN_ANONYMOUS_AUTH_REQUIRED"],
  ] as const)("rejects non-anonymous-svn input without another route", (input, code) => {
    const factory = new RemoteOperationEnvelopeFactory({
      remoteSvnAnonymous: true,
      isRemoteSubmissionEnabled: () => true,
      currentRemoteTrustEpoch: () => 7,
    });
    expect(() => factory.createAnonymousSvn(input)).toThrowError(expect.objectContaining({ code }));
  });

  it("rejects unknown envelope keys", () => {
    const envelope = new RemoteOperationEnvelopeFactory({
      remoteSvnAnonymous: true,
      isRemoteSubmissionEnabled: () => true,
      currentRemoteTrustEpoch: () => 7,
    }).createAnonymousSvn(INPUT);

    expect(() => validateAnonymousSvnRemoteOperationEnvelope({ ...envelope, fallback: true })).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID",
        safeArgs: { field: "remote" },
      }),
    );
  });
});

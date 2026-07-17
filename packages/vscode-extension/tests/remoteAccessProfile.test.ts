import { describe, expect, it } from "vitest";
import {
  buildRemoteOperationEnvelope,
  readRemoteAccessProfiles,
  selectRemoteAccessProfile,
  type RemoteProfileConfigurationInspection,
} from "../src/security/remoteAccessProfile";

const HTTPS_PROFILE = {
  schema: "subversionr.remote-profile.v1",
  profileId: "corp-svn",
  authority: { scheme: "https", canonicalHost: "svn.example.invalid", effectivePort: 443 },
  serverAuth: "basic",
  serverAccount: { mode: "fixed", username: "alice" },
  serverCredentialPersistence: "secretStorage",
  tls: { trust: "windowsRootsThenBroker" },
  proxy: "none",
  ssh: "none",
  redirectPolicy: "rejectAll",
} as const;

describe("remote access profile foundation", () => {
  it("reads a strict machine-scoped Tier-1 snapshot", () => {
    expect(read({ globalValue: [HTTPS_PROFILE] })).toEqual([HTTPS_PROFILE]);
  });

  it.each(["workspaceValue", "workspaceFolderValue", "globalLanguageValue"] as const)(
    "rejects %s instead of ignoring a non-machine profile source",
    (scope) => {
      expect(() => read({ globalValue: [HTTPS_PROFILE], [scope]: [HTTPS_PROFILE] })).toThrowError(
        expect.objectContaining({ code: "SUBVERSIONR_REMOTE_PROFILE_SCOPE_INVALID" }),
      );
    },
  );

  it("rejects unknown fields, profile versions, proxy fields and duplicate identifiers", () => {
    expect(() => read({ globalValue: [{ ...HTTPS_PROFILE, future: true }] })).toThrowError(
      expect.objectContaining({ code: "SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID" }),
    );
    expect(() => read({ globalValue: [{ ...HTTPS_PROFILE, schema: "subversionr.remote-profile.v2" }] })).toThrowError(
      expect.objectContaining({ code: "SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID" }),
    );
    expect(() => read({ globalValue: [{ ...HTTPS_PROFILE, proxy: { authority: HTTPS_PROFILE.authority } }] })).toThrowError(
      expect.objectContaining({ code: "SUBVERSIONR_REMOTE_PROXY_UNSUPPORTED" }),
    );
    expect(() => read({ globalValue: [HTTPS_PROFILE, HTTPS_PROFILE] })).toThrowError(
      expect.objectContaining({ code: "SUBVERSIONR_REMOTE_PROFILE_DUPLICATE_ID" }),
    );
  });

  it("requires canonical authority and exactly one matching profile", () => {
    expect(() => read({ globalValue: [{ ...HTTPS_PROFILE, authority: { ...HTTPS_PROFILE.authority, canonicalHost: "SVN.EXAMPLE.INVALID" } }] })).toThrowError(
      expect.objectContaining({ code: "SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID" }),
    );
    const profiles = read({ globalValue: [HTTPS_PROFILE] });
    expect(selectRemoteAccessProfile(profiles, HTTPS_PROFILE.authority)).toEqual(HTTPS_PROFILE);
    expect(() => selectRemoteAccessProfile(profiles, { ...HTTPS_PROFILE.authority, effectivePort: 8443 })).toThrowError(
      expect.objectContaining({ code: "SUBVERSIONR_REMOTE_PROFILE_MATCH_INVALID", safeArgs: { matchCount: 0 } }),
    );
  });

  it("builds the v1 envelope only after trust acknowledgement and with bounded interaction", () => {
    const profile = read({ globalValue: [HTTPS_PROFILE] })[0]!;
    const input = {
      operationId: "01234567-89ab-cdef-0123-456789abcdef",
      intent: "foreground" as const,
      interaction: "allowed" as const,
      timeoutMs: 30_000,
      trustEpoch: 2,
      profile,
      expectedOrigin: HTTPS_PROFILE.authority,
      remoteSubmissionEnabled: true,
    };
    expect(buildRemoteOperationEnvelope(input)).toEqual({
      version: 1,
      operationId: input.operationId,
      intent: "foreground",
      interaction: "allowed",
      timeoutMs: 30_000,
      workspaceTrust: "trusted",
      trustEpoch: 2,
      profile,
      expectedOrigin: HTTPS_PROFILE.authority,
    });
    expect(() => buildRemoteOperationEnvelope({ ...input, remoteSubmissionEnabled: false })).toThrowError(
      expect.objectContaining({ code: "SUBVERSIONR_REMOTE_TRUST_NOT_ACKNOWLEDGED" }),
    );
    expect(() => buildRemoteOperationEnvelope({ ...input, intent: "background", interaction: "allowed" })).toThrowError(
      expect.objectContaining({ safeArgs: { field: "interaction" } }),
    );
    expect(() => buildRemoteOperationEnvelope({ ...input, timeoutMs: 300_001 })).toThrowError(
      expect.objectContaining({ safeArgs: { field: "timeoutMs" } }),
    );
    expect(() =>
      buildRemoteOperationEnvelope({ ...input, expectedProxy: null } as unknown as typeof input),
    ).toThrowError(expect.objectContaining({ safeArgs: { field: "remote" } }));
    expect(() =>
      buildRemoteOperationEnvelope({
        ...input,
        expectedOrigin: { ...input.expectedOrigin, future: true },
      } as unknown as typeof input),
    ).toThrowError(expect.objectContaining({ safeArgs: { field: "expectedOrigin" } }));
    const chooserProfile = read({
      globalValue: [
        { ...HTTPS_PROFILE, serverAccount: { mode: "chooseForeground" } },
      ],
    })[0]!;
    expect(() =>
      buildRemoteOperationEnvelope({
        ...input,
        intent: "background",
        interaction: "forbidden",
        profile: chooserProfile,
      }),
    ).toThrowError(expect.objectContaining({ safeArgs: { field: "profile.serverAccount" } }));
    expect(() =>
      buildRemoteOperationEnvelope({
        ...input,
        interaction: "forbidden",
        profile: chooserProfile,
      }),
    ).toThrowError(expect.objectContaining({ safeArgs: { field: "profile.serverAccount" } }));
  });
});

function read(inspection: RemoteProfileConfigurationInspection) {
  return readRemoteAccessProfiles({
    inspect: <T>(section: string): T | undefined =>
      (section === "remote.profiles" ? inspection : undefined) as T | undefined,
  });
}

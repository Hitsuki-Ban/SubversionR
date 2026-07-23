import type { RemoteOperationEnvelope } from "../src/security/remoteAccessProfile";

export function anonymousSvnRemoteEnvelope(): RemoteOperationEnvelope {
  return {
    version: 1,
    operationId: "01234567-89ab-4def-8123-456789abcdef",
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: 30_000,
    workspaceTrust: "trusted",
    trustEpoch: 1,
    profile: {
      schema: "subversionr.remote-profile.v1",
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
}

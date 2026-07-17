export const REMOTE_PROFILE_CONFIGURATION_KEY = "subversionr.remote.profiles";
export const REMOTE_PROFILE_SCHEMA = "subversionr.remote-profile.v1";

export type RemoteScheme = "http" | "https" | "svn" | "svn+ssh";
export type RemoteOperationIntent = "foreground" | "background";
export type RemoteInteraction = "allowed" | "forbidden";

export interface CanonicalEndpoint {
  scheme: RemoteScheme;
  canonicalHost: string;
  effectivePort: number;
}

export type ServerAccountSnapshot = "none" | { mode: "fixed"; username: string } | { mode: "chooseForeground" };

export interface RemoteAccessProfileSnapshot {
  schema: typeof REMOTE_PROFILE_SCHEMA;
  profileId: string;
  authority: CanonicalEndpoint;
  serverAuth: "anonymous" | "basic" | "cramMd5";
  serverAccount: ServerAccountSnapshot;
  serverCredentialPersistence: "secretStorage";
  tls?: { trust: "windowsRootsThenBroker" };
  proxy: "none";
  ssh: "none";
  redirectPolicy: "rejectAll";
}

export interface RemoteOperationEnvelope {
  version: 1;
  operationId: string;
  intent: RemoteOperationIntent;
  interaction: RemoteInteraction;
  timeoutMs: number;
  workspaceTrust: "trusted";
  trustEpoch: number;
  profile: RemoteAccessProfileSnapshot;
  expectedOrigin: CanonicalEndpoint;
}

export interface RemoteProfileConfigurationInspection {
  globalValue?: unknown;
  workspaceValue?: unknown;
  workspaceFolderValue?: unknown;
  defaultLanguageValue?: unknown;
  globalLanguageValue?: unknown;
  workspaceLanguageValue?: unknown;
  workspaceFolderLanguageValue?: unknown;
}

export interface RemoteProfileConfigurationReader {
  inspect<T>(section: string): T | undefined;
}

export class RemoteProfileConfigurationError extends Error {
  public constructor(
    public readonly code: string,
    public readonly messageKey: string,
    public readonly safeArgs: Readonly<Record<string, unknown>> = {},
  ) {
    super(code);
    this.name = "RemoteProfileConfigurationError";
  }
}

export function readRemoteAccessProfiles(
  configuration: RemoteProfileConfigurationReader,
): readonly RemoteAccessProfileSnapshot[] {
  const inspection = configuration.inspect<RemoteProfileConfigurationInspection>("remote.profiles");
  if (inspection === undefined) {
    return [];
  }
  if (
    inspection.workspaceValue !== undefined ||
    inspection.workspaceFolderValue !== undefined ||
    inspection.defaultLanguageValue !== undefined ||
    inspection.globalLanguageValue !== undefined ||
    inspection.workspaceLanguageValue !== undefined ||
    inspection.workspaceFolderLanguageValue !== undefined
  ) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_SCOPE_INVALID", "remote.profiles");
  }
  if (inspection.globalValue === undefined) {
    return [];
  }
  if (!Array.isArray(inspection.globalValue)) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", "remote.profiles");
  }

  const profiles = inspection.globalValue.map((value, index) => parseProfile(value, index));
  const ids = new Set<string>();
  for (const profile of profiles) {
    if (ids.has(profile.profileId)) {
      throw configurationError("SUBVERSIONR_REMOTE_PROFILE_DUPLICATE_ID", "remote.profiles");
    }
    ids.add(profile.profileId);
  }
  return profiles;
}

export function selectRemoteAccessProfile(
  profiles: readonly RemoteAccessProfileSnapshot[],
  expectedOrigin: CanonicalEndpoint,
): RemoteAccessProfileSnapshot {
  const canonicalOrigin = parseEndpoint(expectedOrigin, "expectedOrigin");
  const matches = profiles.filter((profile) => endpointsEqual(profile.authority, canonicalOrigin));
  if (matches.length !== 1) {
    throw new RemoteProfileConfigurationError(
      "SUBVERSIONR_REMOTE_PROFILE_MATCH_INVALID",
      "error.remote.profileMatchInvalid",
      { matchCount: matches.length },
    );
  }
  return matches[0]!;
}

export function buildRemoteOperationEnvelope(input: {
  operationId: string;
  intent: RemoteOperationIntent;
  interaction: RemoteInteraction;
  timeoutMs: number;
  trustEpoch: number;
  profile: RemoteAccessProfileSnapshot;
  expectedOrigin: CanonicalEndpoint;
  remoteSubmissionEnabled: boolean;
}): RemoteOperationEnvelope {
  const inputRecord = requireObject(input, "remote");
  requireExactKeys(
    inputRecord,
    [
      "operationId",
      "intent",
      "interaction",
      "timeoutMs",
      "trustEpoch",
      "profile",
      "expectedOrigin",
      "remoteSubmissionEnabled",
    ],
    [],
    "remote",
  );
  if (!input.remoteSubmissionEnabled) {
    throw new RemoteProfileConfigurationError(
      "SUBVERSIONR_REMOTE_TRUST_NOT_ACKNOWLEDGED",
      "error.remote.trustNotAcknowledged",
    );
  }
  if (typeof input.operationId !== "string" || !isCanonicalUuid(input.operationId)) {
    throw configurationError("SUBVERSIONR_REMOTE_ENVELOPE_INVALID", "operationId");
  }
  if (!Number.isSafeInteger(input.timeoutMs) || input.timeoutMs < 1 || input.timeoutMs > 300_000) {
    throw configurationError("SUBVERSIONR_REMOTE_ENVELOPE_INVALID", "timeoutMs");
  }
  if (!Number.isSafeInteger(input.trustEpoch) || input.trustEpoch < 1) {
    throw configurationError("SUBVERSIONR_REMOTE_ENVELOPE_INVALID", "trustEpoch");
  }
  const intent = requireEnum(input.intent, ["foreground", "background"] as const, "intent");
  const interaction = requireEnum(input.interaction, ["allowed", "forbidden"] as const, "interaction");
  if (intent === "background" && interaction !== "forbidden") {
    throw configurationError("SUBVERSIONR_REMOTE_ENVELOPE_INVALID", "interaction");
  }
  const profile = parseProfile(input.profile, 0);
  const expectedOrigin = parseEndpoint(input.expectedOrigin, "expectedOrigin");
  if (
    typeof profile.serverAccount === "object" &&
    profile.serverAccount.mode === "chooseForeground" &&
    (intent !== "foreground" || interaction !== "allowed")
  ) {
    throw configurationError("SUBVERSIONR_REMOTE_ENVELOPE_INVALID", "profile.serverAccount");
  }
  if (!endpointsEqual(profile.authority, expectedOrigin)) {
    throw new RemoteProfileConfigurationError(
      "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
      "error.remote.originMismatch",
    );
  }
  return {
    version: 1,
    operationId: input.operationId,
    intent,
    interaction,
    timeoutMs: input.timeoutMs,
    workspaceTrust: "trusted",
    trustEpoch: input.trustEpoch,
    profile,
    expectedOrigin,
  };
}

function parseProfile(value: unknown, index: number): RemoteAccessProfileSnapshot {
  const profile = requireObject(value, `profiles[${index}]`);
  requireExactKeys(profile, [
    "schema",
    "profileId",
    "authority",
    "serverAuth",
    "serverAccount",
    "serverCredentialPersistence",
    "tls",
    "proxy",
    "ssh",
    "redirectPolicy",
  ], ["tls"], `profiles[${index}]`);

  if (profile.schema !== REMOTE_PROFILE_SCHEMA) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", "schema");
  }
  const profileId = requireString(profile.profileId, "profileId");
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(profileId)) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", "profileId");
  }
  const authority = parseEndpoint(profile.authority, "authority");
  const serverAuth = requireEnum(profile.serverAuth, ["anonymous", "basic", "cramMd5"] as const, "serverAuth");
  const serverAccount = parseServerAccount(profile.serverAccount);
  if (profile.serverCredentialPersistence !== "secretStorage") {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", "serverCredentialPersistence");
  }
  if (profile.proxy !== "none") {
    throw new RemoteProfileConfigurationError(
      "SUBVERSIONR_REMOTE_PROXY_UNSUPPORTED",
      "error.remote.proxyUnsupported",
    );
  }
  if (profile.ssh !== "none" || authority.scheme === "svn+ssh") {
    throw new RemoteProfileConfigurationError(
      "SUBVERSIONR_REMOTE_SSH_PROFILE_UNSUPPORTED",
      "error.remote.sshProfileUnsupported",
    );
  }
  if (profile.redirectPolicy !== "rejectAll") {
    throw new RemoteProfileConfigurationError(
      "SUBVERSIONR_REMOTE_REDIRECT_POLICY_UNSUPPORTED",
      "error.remote.redirectPolicyUnsupported",
    );
  }

  let tls: RemoteAccessProfileSnapshot["tls"];
  if (authority.scheme === "https") {
    const tlsValue = requireObject(profile.tls, "tls");
    requireExactKeys(tlsValue, ["trust"], [], "tls");
    if (tlsValue.trust !== "windowsRootsThenBroker") {
      throw new RemoteProfileConfigurationError(
        "SUBVERSIONR_REMOTE_TLS_POLICY_UNSUPPORTED",
        "error.remote.tlsPolicyUnsupported",
      );
    }
    tls = { trust: "windowsRootsThenBroker" };
  } else if (profile.tls !== undefined) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", "tls");
  }

  if (authority.scheme === "http" || authority.scheme === "https") {
    if (serverAuth !== "anonymous" && serverAuth !== "basic") {
      throw new RemoteProfileConfigurationError("SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED", "error.remote.authUnsupported");
    }
  } else if (serverAuth !== "anonymous" && serverAuth !== "cramMd5") {
    throw new RemoteProfileConfigurationError("SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED", "error.remote.authUnsupported");
  }
  validateAccount(serverAuth, serverAccount);

  return {
    schema: REMOTE_PROFILE_SCHEMA,
    profileId,
    authority,
    serverAuth,
    serverAccount,
    serverCredentialPersistence: "secretStorage",
    ...(tls === undefined ? {} : { tls }),
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
}

function parseEndpoint(value: unknown, field: string): CanonicalEndpoint {
  const endpoint = requireObject(value, field);
  requireExactKeys(endpoint, ["scheme", "canonicalHost", "effectivePort"], [], field);
  if (typeof endpoint.effectivePort !== "number") {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", `${field}.effectivePort`);
  }
  const parsed = {
    scheme: requireEnum(endpoint.scheme, ["http", "https", "svn", "svn+ssh"] as const, `${field}.scheme`),
    canonicalHost: requireString(endpoint.canonicalHost, `${field}.canonicalHost`),
    effectivePort: endpoint.effectivePort,
  };
  validateEndpoint(parsed, field);
  return parsed;
}

function validateEndpoint(value: CanonicalEndpoint, field: string): void {
  if (!Number.isSafeInteger(value.effectivePort) || value.effectivePort < 1 || value.effectivePort > 65_535) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", `${field}.effectivePort`);
  }
  const host = value.canonicalHost;
  if (host.length < 1 || host.length > 253 || !/^[\x00-\x7f]+$/.test(host) || host !== host.toLowerCase()) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", `${field}.canonicalHost`);
  }
  const isIpv4 = /^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){3}$/.test(host) && host.split(".").every((part) => Number(part) <= 255);
  const isIpv6 = host.includes(":") && canonicalIpv6(host);
  const isDns = !host.includes(":") && host.split(".").every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label));
  if (!isIpv4 && !isIpv6 && !isDns) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", `${field}.canonicalHost`);
  }
}

function canonicalIpv6(host: string): boolean {
  try {
    const parsed = new URL(`http://[${host}]/`).hostname;
    return parsed === `[${host}]`;
  } catch {
    return false;
  }
}

function parseServerAccount(value: unknown): ServerAccountSnapshot {
  if (value === "none") {
    return "none";
  }
  const account = requireObject(value, "serverAccount");
  if (account.mode === "chooseForeground") {
    requireExactKeys(account, ["mode"], [], "serverAccount");
    return { mode: "chooseForeground" };
  }
  requireExactKeys(account, ["mode", "username"], [], "serverAccount");
  if (account.mode !== "fixed") {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", "serverAccount.mode");
  }
  const username = requireString(account.username, "serverAccount.username");
  if (username.length > 256 || username !== username.trim() || /[\u0000-\u001f\u007f]/.test(username)) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", "serverAccount.username");
  }
  return { mode: "fixed", username };
}

function validateAccount(serverAuth: RemoteAccessProfileSnapshot["serverAuth"], account: ServerAccountSnapshot): void {
  if ((serverAuth === "anonymous") !== (account === "none")) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", "serverAccount");
  }
}

function requireObject(value: unknown, field: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", field);
  }
  return value as Record<string, unknown>;
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", field);
  }
  return value;
}

function requireEnum<const T extends readonly string[]>(value: unknown, allowed: T, field: string): T[number] {
  if (typeof value !== "string" || !allowed.includes(value)) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", field);
  }
  return value as T[number];
}

function requireExactKeys(
  value: Record<string, unknown>,
  known: readonly string[],
  optional: readonly string[],
  field: string,
): void {
  const required = known.filter((key) => !optional.includes(key));
  if (Object.keys(value).some((key) => !known.includes(key)) || required.some((key) => !(key in value))) {
    throw configurationError("SUBVERSIONR_REMOTE_PROFILE_CONTRACT_INVALID", field);
  }
}

function endpointsEqual(left: CanonicalEndpoint, right: CanonicalEndpoint): boolean {
  return left.scheme === right.scheme && left.canonicalHost === right.canonicalHost && left.effectivePort === right.effectivePort;
}

function isCanonicalUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value) && !/^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(value);
}

function configurationError(code: string, field: string): RemoteProfileConfigurationError {
  return new RemoteProfileConfigurationError(code, "error.remote.contractInvalid", { field });
}

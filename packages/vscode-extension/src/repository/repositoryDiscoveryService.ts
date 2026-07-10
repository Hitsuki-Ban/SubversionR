import type { BackendService } from "../backend/backendService";
import type {
  RepositoryIdentity,
  RepositorySession,
  RepositorySessionService,
} from "./repositorySessionService";
import type { PathCasePolicy } from "../status/types";

export type RepositoryDiscoveryErrorCategory = "input" | "protocol" | "unsupported";
export type RepositoryDiscoveryExternalsMode = "off" | "lazy";

export interface RepositoryDiscoveryServiceOptions {
  backendService: Pick<BackendService, "initialize">;
  sessionService: Pick<RepositorySessionService, "openWorkingCopy">;
}

export interface RepositoryDiscoveryRequest {
  workspaceRoots: string[];
  discoverNested: boolean;
  discoveryDepth: number;
  discoveryIgnore: string[];
  ignoredRoots: string[];
  externalsMode: RepositoryDiscoveryExternalsMode;
}

export interface RepositoryDiscoveryCandidate {
  identity: RepositoryIdentity;
  isNested: boolean;
  isExternal: boolean;
  parentWorkingCopyRoot?: string;
}

export interface RepositoryDiscoveryResponse {
  candidates: RepositoryDiscoveryCandidate[];
  fileExternalBoundaries: string[];
}

export interface OpenDiscoveredRepositoryRequest {
  candidate: RepositoryDiscoveryCandidate;
  pathCase: PathCasePolicy;
  boundaryRoots?: string[];
}

export class RepositoryDiscoveryError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: RepositoryDiscoveryErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
    options?: ErrorOptions,
  ) {
    super(code, options);
    this.name = "RepositoryDiscoveryError";
  }
}

export class RepositoryDiscoveryService {
  public constructor(private readonly options: RepositoryDiscoveryServiceOptions) {}

  public async discoverRepositories(request: RepositoryDiscoveryRequest): Promise<RepositoryDiscoveryResponse> {
    const validatedRequest = validateDiscoveryRequest(request);
    const connection = await this.options.backendService.initialize();
    return parseDiscoveryResponse(await connection.sendRequest<unknown>("repository/discover", validatedRequest));
  }

  public async openDiscoveredRepository(request: OpenDiscoveredRepositoryRequest): Promise<RepositorySession> {
    const validatedRequest = validateOpenDiscoveredRepositoryRequest(request);
    return await this.options.sessionService.openWorkingCopy({
      path: validatedRequest.candidate.identity.workingCopyRoot,
      pathCase: validatedRequest.pathCase,
      ...(validatedRequest.boundaryRoots ? { boundaryRoots: validatedRequest.boundaryRoots } : {}),
    });
  }
}

interface ValidatedOpenDiscoveredRepositoryRequest {
  candidate: RepositoryDiscoveryCandidate;
  pathCase: PathCasePolicy;
  boundaryRoots?: string[];
}

function validateDiscoveryRequest(request: RepositoryDiscoveryRequest): RepositoryDiscoveryRequest {
  if (!isRecord(request)) {
    throw invalidDiscoveryInput("request");
  }

  return {
    workspaceRoots: requireStringArray(request.workspaceRoots, "workspaceRoots", false),
    discoverNested: requireBoolean(request.discoverNested, "discoverNested"),
    discoveryDepth: requireNonNegativeSafeInteger(request.discoveryDepth, "discoveryDepth"),
    discoveryIgnore: requireStringArray(request.discoveryIgnore, "discoveryIgnore", true),
    ignoredRoots: requireStringArray(request.ignoredRoots, "ignoredRoots", true),
    externalsMode: requireSupportedExternalsMode(request.externalsMode),
  };
}

function validateOpenDiscoveredRepositoryRequest(
  request: OpenDiscoveredRepositoryRequest,
): ValidatedOpenDiscoveredRepositoryRequest {
  if (!isRecord(request)) {
    throw invalidDiscoveryInput("request");
  }
  const candidate = parseDiscoveryCandidate(request.candidate, "candidate");
  if (request.pathCase !== "case-sensitive" && request.pathCase !== "case-insensitive") {
    throw invalidDiscoveryInput("pathCase");
  }

  return {
    candidate,
    pathCase: request.pathCase,
    boundaryRoots: validateOptionalStringArray(request.boundaryRoots, "boundaryRoots"),
  };
}

function parseDiscoveryResponse(rawResponse: unknown): RepositoryDiscoveryResponse {
  const response = requireRecord(rawResponse, "result");
  const candidates = response.candidates;
  if (!Array.isArray(candidates)) {
    throw invalidDiscoveryResponse("candidates");
  }

  return {
    candidates: candidates.map((candidate, index) => parseDiscoveryCandidate(candidate, `candidates.${index}`)),
    fileExternalBoundaries: requireResponseStringArray(response.fileExternalBoundaries, "fileExternalBoundaries", true),
  };
}

function parseDiscoveryCandidate(rawCandidate: unknown, field: string): RepositoryDiscoveryCandidate {
  const candidate = requireRecord(rawCandidate, field);
  const identity = parseRepositoryIdentity(candidate.identity, `${field}.identity`);
  const isNested = requireResponseBoolean(candidate.isNested, `${field}.isNested`);
  const isExternal = requireResponseBoolean(candidate.isExternal, `${field}.isExternal`);
  const parentWorkingCopyRoot = optionalResponseString(
    candidate.parentWorkingCopyRoot,
    `${field}.parentWorkingCopyRoot`,
  );
  if ((isNested || isExternal) && parentWorkingCopyRoot === undefined) {
    throw invalidDiscoveryResponse(`${field}.parentWorkingCopyRoot`);
  }
  if (!isNested && !isExternal && parentWorkingCopyRoot !== undefined) {
    throw invalidDiscoveryResponse(`${field}.parentWorkingCopyRoot`);
  }

  return {
    identity,
    isNested,
    isExternal,
    ...(parentWorkingCopyRoot ? { parentWorkingCopyRoot } : {}),
  };
}

function parseRepositoryIdentity(rawIdentity: unknown, field: string): RepositoryIdentity {
  const identity = requireRecord(rawIdentity, field);
  return {
    repositoryUuid: requireResponseString(identity.repositoryUuid, `${field}.repositoryUuid`),
    repositoryRootUrl: requireResponseString(identity.repositoryRootUrl, `${field}.repositoryRootUrl`),
    workingCopyRoot: requireResponseString(identity.workingCopyRoot, `${field}.workingCopyRoot`),
    workspaceScopeRoot: requireResponseString(identity.workspaceScopeRoot, `${field}.workspaceScopeRoot`),
    format: requireResponseSafeInteger(identity.format, `${field}.format`),
  };
}

function requireStringArray(value: unknown, field: string, allowEmpty: boolean): string[] {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0)) {
    throw invalidDiscoveryInput(field);
  }
  return value.map((item, index) => {
    if (typeof item !== "string" || item.trim().length === 0) {
      throw invalidDiscoveryInput(`${field}.${index}`);
    }
    return item;
  });
}

function validateOptionalStringArray(value: unknown, field: string): string[] | undefined {
  if (value === undefined) {
    return undefined;
  }
  return requireStringArray(value, field, true);
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidDiscoveryInput(field);
  }
  return value;
}

function requireNonNegativeSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidDiscoveryInput(field);
  }
  return value;
}

function requireSupportedExternalsMode(value: unknown): RepositoryDiscoveryExternalsMode {
  if (value === "off" || value === "lazy") {
    return value;
  }
  throw new RepositoryDiscoveryError(
    "SUBVERSIONR_REPOSITORY_DISCOVERY_MODE_UNSUPPORTED",
    "unsupported",
    "error.repository.discoveryModeUnsupported",
    { field: "externalsMode" },
  );
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidDiscoveryResponse(field);
  }
  return value;
}

function requireResponseString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidDiscoveryResponse(field);
  }
  return value;
}

function requireResponseStringArray(value: unknown, field: string, allowEmpty: boolean): string[] {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0)) {
    throw invalidDiscoveryResponse(field);
  }
  return value.map((item, index) => requireResponseString(item, `${field}.${index}`));
}

function optionalResponseString(value: unknown, field: string): string | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidDiscoveryResponse(field);
  }
  return value;
}

function requireResponseBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidDiscoveryResponse(field);
  }
  return value;
}

function requireResponseSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidDiscoveryResponse(field);
  }
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function invalidDiscoveryInput(field: string): RepositoryDiscoveryError {
  return new RepositoryDiscoveryError(
    "SUBVERSIONR_REPOSITORY_DISCOVERY_INPUT_INVALID",
    "input",
    "error.repository.discoveryInputInvalid",
    { field },
  );
}

function invalidDiscoveryResponse(field: string): RepositoryDiscoveryError {
  return new RepositoryDiscoveryError(
    "SUBVERSIONR_REPOSITORY_DISCOVERY_RESPONSE_INVALID",
    "protocol",
    "error.repository.discoveryResponseInvalid",
    { field },
  );
}

import {
  createCertificateTrustRequestHandler,
  type CertificateTrustController,
} from "./certificateTrustController";
import {
  createCredentialRequestHandler,
  type CredentialController,
} from "./credentialController";

export interface AuthRequestHandlerOptions {
  credentialController: CredentialController;
  certificateTrustController: CertificateTrustController;
}

export class AuthRequestRpcError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: string,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown>,
    public readonly retryable = false,
  ) {
    super(code);
    this.name = "AuthRequestRpcError";
  }
}

export function createAuthRequestHandler(options: AuthRequestHandlerOptions): (method: string, params: unknown) => Promise<unknown> {
  const credentialRequestHandler = createCredentialRequestHandler(options.credentialController);
  const certificateTrustRequestHandler = createCertificateTrustRequestHandler(options.certificateTrustController);

  return async (method, params) => {
    if (method === "credentials/request") {
      return await credentialRequestHandler(method, params);
    }
    if (method === "certificate/request") {
      return await certificateTrustRequestHandler(method, params);
    }
    throw new AuthRequestRpcError("RPC_METHOD_NOT_FOUND", "unsupported", "error.rpc.methodNotFound", {
      method,
    });
  };
}

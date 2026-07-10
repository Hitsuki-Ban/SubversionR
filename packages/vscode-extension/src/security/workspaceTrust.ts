export const WORKSPACE_UNTRUSTED_OPERATION_CODE = "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION";

export class WorkspaceTrustError extends Error {
  public readonly code = WORKSPACE_UNTRUSTED_OPERATION_CODE;
  public readonly category = "lifecycle";
  public readonly messageKey = "error.workspace.untrustedOperation";
  public readonly safeArgs: Record<string, unknown> = {};

  public constructor() {
    super(WORKSPACE_UNTRUSTED_OPERATION_CODE);
    this.name = "WorkspaceTrustError";
  }
}

export function requireTrustedWorkspace(workspaceTrusted: () => boolean): void {
  if (!workspaceTrusted()) {
    throw new WorkspaceTrustError();
  }
}

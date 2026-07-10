import { BackendLaunchError, type BackendLaunchConfig } from "./backendProcess";
import type { BackendPackageResources } from "./backendPackageResolver";

export interface BackendConfigurationContext {
  clientName: string;
  clientVersion: string;
  locale: string;
  cacheRoot: string;
  workspaceTrusted: boolean;
  baseEnv: NodeJS.ProcessEnv;
}

export function backendLaunchConfigFromPackageResources(
  resources: BackendPackageResources,
  context: BackendConfigurationContext,
): BackendLaunchConfig {
  return {
    executablePath: resources.executablePath,
    bridgeDllPath: resources.bridgeDllPath,
    cacheRoot: requiredContext(context.cacheRoot, "cacheRoot"),
    clientName: requiredContext(context.clientName, "clientName"),
    clientVersion: requiredContext(context.clientVersion, "clientVersion"),
    locale: requiredContext(context.locale, "locale"),
    workspaceTrust: context.workspaceTrusted ? "trusted" : "untrusted",
    baseEnv: context.baseEnv,
  };
}

function requiredContext(value: string, field: string): string {
  if (value.trim().length === 0) {
    throw new BackendLaunchError("SUBVERSIONR_BACKEND_CONFIG_REQUIRED", "configuration", "error.backend.configRequired", {
      field,
    });
  }
  return value;
}

import type { HistoryCopyTarget } from "./historyTreeDataProvider";

export interface HistoryCopyTargetProvider {
  copyTarget(element: unknown): HistoryCopyTarget;
}

export interface HistoryCopyCommandHost {
  writeText(value: string): Promise<void>;
  showInformationMessage(message: string): Promise<void>;
  localize(message: string, ...args: unknown[]): string;
}

export async function copyHistoryRevisionNumber(
  provider: HistoryCopyTargetProvider,
  element: unknown,
  host: HistoryCopyCommandHost,
): Promise<void> {
  const target = provider.copyTarget(element);
  const revisionNumber = String(target.revision);
  await host.writeText(revisionNumber);
  await host.showInformationMessage(host.localize("Copied SVN revision number: {0}", revisionNumber));
}

export async function copyHistoryCommitMessage(
  provider: HistoryCopyTargetProvider,
  element: unknown,
  host: HistoryCopyCommandHost,
): Promise<void> {
  const target = provider.copyTarget(element);
  await host.writeText(target.message ?? "");
  await host.showInformationMessage(host.localize("Copied SVN commit message."));
}

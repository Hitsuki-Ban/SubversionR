import type * as vscode from "vscode";
import { parseRevisionContentUri, type RevisionContentUriComponents } from "./revisionContentUri";
import type { ContentClient } from "./contentGetRpcClient";
import type { RemoteOperationEnvelope } from "../security/remoteAccessProfile";
import { requireTrustedWorkspace } from "../security/workspaceTrust";

export interface RevisionContentDocumentProviderOptions {
  contentClient: ContentClient;
  createRemoteEnvelope(input: { repositoryId: string; epoch: number }): Promise<RemoteOperationEnvelope | undefined>;
  workspaceTrusted(): boolean;
  localize(message: string, ...args: unknown[]): string;
}

export class RevisionContentDocumentProvider {
  public constructor(private readonly options: RevisionContentDocumentProviderOptions) {}

  public async provideTextDocumentContent(
    uri: RevisionContentUriComponents,
    token: vscode.CancellationToken,
  ): Promise<string> {
    requireTrustedWorkspace(this.options.workspaceTrusted);
    const cancellation = cancellationFromToken(token);
    try {
      cancellation.throwIfCancelled();
      const request = parseRevisionContentUri(uri);
      const remote = await this.options.createRemoteEnvelope({
        repositoryId: request.repositoryId,
        epoch: request.epoch,
      });
      cancellation.throwIfCancelled();
      const content = await this.options.contentClient.getContent(
        {
          repositoryId: request.repositoryId,
          epoch: request.epoch,
          path: request.path,
          revision: request.revision,
          ...(remote === undefined ? {} : { remote }),
        },
        { signal: cancellation.signal },
      );
      if (content.isBinary) {
        return this.options.localize(
          "Binary SVN revision content is not displayed in the text editor: {0}@{1}",
          request.path,
          request.revision,
        );
      }
      return new TextDecoder("utf-8", { fatal: false }).decode(content.bytes);
    } finally {
      cancellation.dispose();
    }
  }
}

function cancellationFromToken(token: vscode.CancellationToken): {
  signal: AbortSignal;
  throwIfCancelled(): void;
  dispose(): void;
} {
  const controller = new AbortController();
  const subscription = token.onCancellationRequested(() => controller.abort());
  if (token.isCancellationRequested) {
    controller.abort();
  }
  return {
    signal: controller.signal,
    throwIfCancelled: () => controller.signal.throwIfAborted(),
    dispose: () => subscription.dispose(),
  };
}

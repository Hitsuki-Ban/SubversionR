import { parseRevisionContentUri, type RevisionContentUriComponents } from "./revisionContentUri";
import type { ContentClient } from "./contentGetRpcClient";
import { requireTrustedWorkspace } from "../security/workspaceTrust";

export interface RevisionContentDocumentProviderOptions {
  contentClient: ContentClient;
  workspaceTrusted(): boolean;
  localize(message: string, ...args: unknown[]): string;
}

export class RevisionContentDocumentProvider {
  public constructor(private readonly options: RevisionContentDocumentProviderOptions) {}

  public async provideTextDocumentContent(uri: RevisionContentUriComponents): Promise<string> {
    requireTrustedWorkspace(this.options.workspaceTrusted);
    const request = parseRevisionContentUri(uri);
    const content = await this.options.contentClient.getContent({
      repositoryId: request.repositoryId,
      epoch: request.epoch,
      path: request.path,
      revision: request.revision,
    });
    if (content.isBinary) {
      return this.options.localize(
        "Binary SVN revision content is not displayed in the text editor: {0}@{1}",
        request.path,
        request.revision,
      );
    }
    return new TextDecoder("utf-8", { fatal: false }).decode(content.bytes);
  }
}

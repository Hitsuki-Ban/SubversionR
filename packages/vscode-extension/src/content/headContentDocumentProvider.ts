import { parseHeadContentUri, type HeadContentUriComponents } from "./headContentUri";
import type { ContentClient } from "./contentGetRpcClient";
import { requireTrustedWorkspace } from "../security/workspaceTrust";

export interface HeadContentDocumentProviderOptions {
  contentClient: ContentClient;
  workspaceTrusted(): boolean;
  localize(message: string, ...args: unknown[]): string;
}

export class HeadContentDocumentProvider {
  public constructor(private readonly options: HeadContentDocumentProviderOptions) {}

  public async provideTextDocumentContent(uri: HeadContentUriComponents): Promise<string> {
    requireTrustedWorkspace(this.options.workspaceTrusted);
    const request = parseHeadContentUri(uri);
    const content = await this.options.contentClient.getContent({
      repositoryId: request.repositoryId,
      epoch: request.epoch,
      path: request.path,
      revision: request.revision,
    });
    if (content.isBinary) {
      return this.options.localize(
        "Binary SVN HEAD content is not displayed in the text editor: {0}",
        request.path,
      );
    }
    return new TextDecoder("utf-8", { fatal: false }).decode(content.bytes);
  }
}

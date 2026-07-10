import { parseBaseContentUri, type BaseContentUriComponents } from "./baseContentUri";
import type { ContentClient } from "./contentGetRpcClient";

export interface BaseContentDocumentProviderOptions {
  contentClient: ContentClient;
  localize(message: string): string;
}

export class BaseContentDocumentProvider {
  public constructor(private readonly options: BaseContentDocumentProviderOptions) {}

  public async provideTextDocumentContent(uri: BaseContentUriComponents): Promise<string> {
    const request = parseBaseContentUri(uri);
    const content = await this.options.contentClient.getContent({
      repositoryId: request.repositoryId,
      epoch: request.epoch,
      path: request.path,
      revision: request.revision,
    });
    if (content.isBinary) {
      return this.options.localize("Binary SVN BASE content is not displayed in the text editor.");
    }
    return new TextDecoder("utf-8", { fatal: false }).decode(content.bytes);
  }
}

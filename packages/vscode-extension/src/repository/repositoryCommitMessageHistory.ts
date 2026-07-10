export interface RepositoryCommitMessageHistoryOptions {
  maxMessages?: number;
}

const DEFAULT_MAX_MESSAGES = 20;

export class RepositoryCommitMessageHistory {
  private readonly maxMessages: number;
  private readonly histories = new Map<string, string[]>();

  public constructor(options: RepositoryCommitMessageHistoryOptions = {}) {
    this.maxMessages = positiveIntegerOrDefault(options.maxMessages, DEFAULT_MAX_MESSAGES);
  }

  public record(repositoryId: string, message: string): void {
    if (message.trim().length === 0) {
      return;
    }
    const existing = this.histories.get(repositoryId) ?? [];
    const messages = [message, ...existing.filter((entry) => entry !== message)].slice(0, this.maxMessages);
    this.histories.set(repositoryId, messages);
  }

  public messages(repositoryId: string): string[] {
    return [...(this.histories.get(repositoryId) ?? [])];
  }
}

function positiveIntegerOrDefault(value: number | undefined, fallback: number): number {
  if (value === undefined) {
    return fallback;
  }
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`Repository commit message history maxMessages must be a positive integer: ${value}`);
  }
  return value;
}

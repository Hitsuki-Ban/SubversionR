export interface InitializeCommandHandlerOptions<TConnection> {
  initialize(): Promise<TConnection>;
  onReady(connection: TConnection): void;
  recordFailure(error: unknown): void;
  failureMessage(error: unknown): string;
  showErrorMessage(message: string, action: string): PromiseLike<string | undefined>;
  showLogAction: string;
  showLog(): void;
  recordNotificationFailure(error: unknown): void;
}

export function createInitializeCommandHandler<TConnection>(
  options: InitializeCommandHandlerOptions<TConnection>,
): () => Promise<void> {
  return async () => {
    try {
      const connection = await options.initialize();
      options.onReady(connection);
    } catch (error) {
      options.recordFailure(error);
      void Promise.resolve()
        .then(() => options.showErrorMessage(options.failureMessage(error), options.showLogAction))
        .then((selected) => {
          if (selected === options.showLogAction) {
            options.showLog();
          }
        })
        .catch((notificationError: unknown) => {
          options.recordNotificationFailure(notificationError);
        });
    }
  };
}

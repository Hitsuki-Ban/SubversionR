import { redactDiagnosticValue } from "./diagnosticsRedaction";

export interface InstalledRedactionReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  collectDiagnosticsBundle(): Promise<Record<string, unknown>>;
}

export async function collectInstalledRedactionReport(
  options: InstalledRedactionReportOptions,
): Promise<Record<string, unknown>> {
  if (typeof options.expectedToken !== "string" || options.expectedToken.length === 0) {
    throw forbidden();
  }
  if (requestToken(options.request) !== options.expectedToken) {
    throw forbidden();
  }

  return {
    schemaVersion: 1,
    kind: "subversionr.installedRedactionReport",
    diagnosticsBundle: await options.collectDiagnosticsBundle(),
    publicSupportFixture: installedPublicSupportRedactionFixture(),
  };
}

export class InstalledRedactionReportError extends Error {
  public constructor(
    public readonly code: string,
    public readonly messageKey: string,
  ) {
    super(code);
    this.name = "InstalledRedactionReportError";
  }
}

function forbidden(): InstalledRedactionReportError {
  return new InstalledRedactionReportError(
    "SUBVERSIONR_INSTALLED_REDACTION_REPORT_FORBIDDEN",
    "error.diagnostics.installedRedactionReportForbidden",
  );
}

function requestToken(request: unknown): string | undefined {
  if (typeof request !== "object" || request === null || !("token" in request)) {
    return undefined;
  }
  const token = (request as { token?: unknown }).token;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function installedPublicSupportRedactionFixture(): Record<string, unknown> {
  return {
    status: "redacted",
    fixture: redactDiagnosticValue({
      operationJournal: {
        entries: [
          {
            repositoryUrl: "https://alice:hunter2@example.com/repos/private?token=abc123",
            path: "C:\\Users\\Alice\\workspace\\project\\src\\main.ts",
            repositoryLogMessage: "Fix production password leak",
            sourceContent: "const password = 'abc123';",
            credential: "hunter2",
          },
        ],
        omittedFields: ["paths", "urls", "repositoryLogMessages", "sourceContent", "credentials"],
      },
      watcherOverflowDiagnostics: {
        lastOverflow: {
          rawPath: "C:/Users/Alice/workspace/project/.svn/wc.db",
          remoteAuthority: "ssh-remote+alice@example.com",
          lastError: "Authorization: Bearer super-secret-token",
        },
        samples: ["svn://bob:secret@example.net/repos/project"],
      },
    }),
  };
}

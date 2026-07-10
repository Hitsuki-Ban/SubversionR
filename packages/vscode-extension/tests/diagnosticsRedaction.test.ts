import { describe, expect, it } from "vitest";
import { redactDiagnosticText, redactDiagnosticValue } from "../src/diagnostics/diagnosticsRedaction";

describe("diagnostics redaction", () => {
  it("redacts credentials urls paths repository log messages and source content recursively", () => {
    const redacted = redactDiagnosticValue({
      backendStderr:
        "svn: E170013: https://alice:hunter2@example.com/repos/project?token=abc123 failed at C:\\Users\\Alice\\wc\\secret.txt\nAuthorization: Bearer super-secret-token",
      repositoryRootUrl: "https://alice:hunter2@example.com/repos/project?password=abc123",
      workingCopyRoot: "C:\\Users\\Alice\\wc",
      logMessage: "Fix production password leak",
      sourceContent: "const password = 'abc123';",
      nested: {
        clientCertPassword: "cert-secret",
        commandLine: "svn --password abc123 update \\\\server\\share\\wc",
      },
    });

    const json = JSON.stringify(redacted);
    expect(json).not.toContain("hunter2");
    expect(json).not.toContain("abc123");
    expect(json).not.toContain("super-secret-token");
    expect(json).not.toContain("Alice");
    expect(json).not.toContain("example.com");
    expect(json).not.toContain("Fix production password leak");
    expect(json).not.toContain("const password");
    expect(json).toContain("[REDACTED:url:");
    expect(json).toContain("[REDACTED:path:");
    expect(json).toContain("[REDACTED:secret]");
    expect(json).toContain("[REDACTED:repository-log]");
    expect(json).toContain("[REDACTED:source-content]");
  });

  it("handles encoded credentials svn ssh urls long windows paths unc paths and repeated redaction safely", () => {
    const text =
      "svn+ssh://alice%40corp:pa%3Ass@[2001:db8::1]/repo/path?private=1 \\\\?\\C:\\Users\\Alice\\wc\\file.txt \\\\server\\share\\wc\\file.txt [REDACTED:secret]";

    const once = redactDiagnosticText(text);
    const twice = redactDiagnosticText(once);

    expect(once).not.toContain("alice");
    expect(once).not.toContain("corp");
    expect(once).not.toContain("pa%3Ass");
    expect(once).not.toContain("Users");
    expect(once).not.toContain("server");
    expect(once).toContain("[REDACTED:url:");
    expect(once).toContain("[REDACTED:path:");
    expect(twice).toBe(once);
  });

  it("redacts mixed-case secret keys slash paths common POSIX roots and remote authorities", () => {
    const redacted = redactDiagnosticValue({
      accessToken: "token-123",
      authToken: "auth-456",
      Authorization: "Bearer bearer-789",
      Cookie: "session=secret-cookie",
      remoteAuthority: "ssh-remote+alice@example.com",
      windowsSlashPath: "C:/Users/Alice/wc/file.txt",
      quotedPosixPath: '"/srv/repos/private/project"',
      optToolPath: "/opt/tools/subversionr/bin/daemon",
    });

    const json = JSON.stringify(redacted);
    expect(json).not.toContain("token-123");
    expect(json).not.toContain("auth-456");
    expect(json).not.toContain("bearer-789");
    expect(json).not.toContain("secret-cookie");
    expect(json).not.toContain("alice@example.com");
    expect(json).not.toContain("Users");
    expect(json).not.toContain("srv");
    expect(json).not.toContain("/opt/tools");
    expect(json).toContain("[REDACTED:secret]");
    expect(json).toContain("[REDACTED:remote:");
    expect(json).toContain("[REDACTED:path:");
  });

  it("redacts the public support redaction fixture categories", () => {
    const text = [
      "https://alice:hunter2@example.com/repos/private?token=abc123",
      "svn://bob:secret@example.net/repos/project",
      "C:\\Users\\Alice\\workspace\\project\\.svn\\wc.db",
      "C:/Users/Alice/workspace/project/.svn/wc.db",
      "Authorization: Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==",
      "Cookie: session=secret-cookie",
      "Stack trace at C:\\Users\\Alice\\workspace\\project\\src\\main.ts",
    ].join("\n");

    const redacted = redactDiagnosticText(text);

    expect(redacted).not.toContain("hunter2");
    expect(redacted).not.toContain("abc123");
    expect(redacted).not.toContain("bob");
    expect(redacted).not.toContain("secret@example.net");
    expect(redacted).not.toContain(".svn\\wc.db");
    expect(redacted).not.toContain(".svn/wc.db");
    expect(redacted).not.toContain("QWxhZGRpbjpvcGVuIHNlc2FtZQ==");
    expect(redacted).not.toContain("secret-cookie");
    expect(redacted).not.toContain("Alice");
    expect(redacted).toContain("[REDACTED:url:");
    expect(redacted).toContain("[REDACTED:path:");
    expect(redacted).toContain("[REDACTED:secret]");
  });

  it("redacts operation journal and watcher metrics in the public support redaction fixture", () => {
    const redacted = redactDiagnosticValue({
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
    });

    const json = JSON.stringify(redacted);
    expect(json).not.toContain("hunter2");
    expect(json).not.toContain("abc123");
    expect(json).not.toContain("Alice");
    expect(json).not.toContain("example.com");
    expect(json).not.toContain(".svn/wc.db");
    expect(json).not.toContain("Fix production password leak");
    expect(json).not.toContain("const password");
    expect(json).not.toContain("super-secret-token");
    expect(json).toContain("operationJournal");
    expect(json).toContain("watcherOverflowDiagnostics");
    expect(json).toContain("[REDACTED:url:");
    expect(json).toContain("[REDACTED:path:");
    expect(json).toContain("[REDACTED:remote:");
    expect(json).toContain("[REDACTED:secret]");
    expect(json).toContain("[REDACTED:repository-log]");
    expect(json).toContain("[REDACTED:source-content]");
  });
});

import { describe, expect, it, vi } from "vitest";
import {
  DIAGNOSTICS_DOCUMENT_URI_SCHEME,
  DiagnosticsReadonlyDocumentProvider,
} from "../src/diagnostics/diagnosticsDocumentProvider";

describe("DiagnosticsReadonlyDocumentProvider", () => {
  it("stores version report JSON behind a readonly diagnostics URI", () => {
    const provider = new DiagnosticsReadonlyDocumentProvider({
      createEventEmitter: () => ({
        event: vi.fn(() => ({ dispose: vi.fn() })),
        fire: vi.fn(),
        dispose: vi.fn(),
      }),
      uriFromComponents: (components) => components,
    });

    const uri = provider.createDocument('{"kind":"subversionr.versionReport"}\n');

    expect(uri).toMatchObject({
      scheme: DIAGNOSTICS_DOCUMENT_URI_SCHEME,
      authority: "readonly",
      path: "/version-report.json",
    });
    expect(provider.provideTextDocumentContent(uri)).toBe('{"kind":"subversionr.versionReport"}\n');
  });

  it("releases diagnostics documents when the backing text document closes", () => {
    const provider = new DiagnosticsReadonlyDocumentProvider({
      createEventEmitter: () => ({
        event: vi.fn(() => ({ dispose: vi.fn() })),
        fire: vi.fn(),
        dispose: vi.fn(),
      }),
      uriFromComponents: (components) => components,
    });
    const uri = provider.createDocument("{}\n");

    provider.releaseDocument(uri);

    expect(() => provider.provideTextDocumentContent(uri)).toThrow(
      expect.objectContaining({ code: "SUBVERSIONR_DIAGNOSTICS_DOCUMENT_NOT_FOUND" }),
    );
  });
});

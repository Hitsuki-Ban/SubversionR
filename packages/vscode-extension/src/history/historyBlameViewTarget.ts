import type { HistoryBlameDocumentRequest } from "./historyBlameDocument";

export interface HistoryBlameViewTarget extends HistoryBlameDocumentRequest {
  label: string;
}

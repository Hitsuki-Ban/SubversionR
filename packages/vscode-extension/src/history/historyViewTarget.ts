export type HistoryViewTargetKind = "repository" | "file" | "line";

export interface HistoryViewTarget {
  kind: HistoryViewTargetKind;
  repositoryId: string;
  epoch: number;
  path: string;
  label: string;
  lineStart?: number;
  lineEnd?: number;
}

export interface MergeRecordOnlyQuickPickItem {
  label: string;
  description: string;
  recordOnly: boolean;
}

export interface MergeIgnoreMergeinfoQuickPickItem {
  label: string;
  description: string;
  ignoreMergeinfo: boolean;
}

export interface MergeAncestryQuickPickItem {
  label: string;
  description: string;
  diffIgnoreAncestry: boolean;
}

export interface MergeMixedRevisionsQuickPickItem {
  label: string;
  description: string;
  allowMixedRevisions: boolean;
}

export interface MergeForceDeleteQuickPickItem {
  label: string;
  description: string;
  forceDelete: boolean;
}

export function mergeRecordOnlyQuickPickItems(
  localize: (message: string) => string,
): MergeRecordOnlyQuickPickItem[] {
  return [
    {
      label: localize("Apply merge"),
      description: localize("Apply file and property changes during merge"),
      recordOnly: false,
    },
    {
      label: localize("Record only"),
      description: localize("Record mergeinfo without applying file changes"),
      recordOnly: true,
    },
  ];
}

export function mergeIgnoreMergeinfoQuickPickItems(
  localize: (message: string) => string,
): MergeIgnoreMergeinfoQuickPickItem[] {
  return [
    {
      label: localize("Use mergeinfo"),
      description: localize("Let libsvn skip revisions already recorded in mergeinfo"),
      ignoreMergeinfo: false,
    },
    {
      label: localize("Ignore mergeinfo"),
      description: localize("Merge the requested revision range without mergeinfo filtering"),
      ignoreMergeinfo: true,
    },
  ];
}

export function mergeAncestryQuickPickItems(
  localize: (message: string) => string,
): MergeAncestryQuickPickItem[] {
  return [
    {
      label: localize("Check ancestry"),
      description: localize("Require shared SVN ancestry during merge"),
      diffIgnoreAncestry: false,
    },
    {
      label: localize("Ignore ancestry"),
      description: localize("Allow merge without checking SVN ancestry"),
      diffIgnoreAncestry: true,
    },
  ];
}

export function mergeMixedRevisionsQuickPickItems(
  localize: (message: string) => string,
): MergeMixedRevisionsQuickPickItem[] {
  return [
    {
      label: localize("Require uniform revisions"),
      description: localize("Reject merge targets with mixed working copy revisions"),
      allowMixedRevisions: false,
    },
    {
      label: localize("Allow mixed revisions"),
      description: localize("Allow merge targets with mixed working copy revisions"),
      allowMixedRevisions: true,
    },
  ];
}

export function mergeForceDeleteQuickPickItems(
  localize: (message: string) => string,
): MergeForceDeleteQuickPickItem[] {
  return [
    {
      label: localize("Prevent forced deletes"),
      description: localize("Reject merge deletes that require libsvn force-delete"),
      forceDelete: false,
    },
    {
      label: localize("Allow forced deletes"),
      description: localize("Allow libsvn force-delete behavior during merge"),
      forceDelete: true,
    },
  ];
}

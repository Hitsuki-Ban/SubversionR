const MAX_SVN_REVNUM = 2_147_483_647;

export function parseUpdateRevisionInput(value: string): number | undefined {
  const text = value.trim();
  if (!/^(0|[1-9]\d*)$/.test(text)) {
    return undefined;
  }
  const revision = Number(text);
  if (!Number.isSafeInteger(revision) || revision > MAX_SVN_REVNUM) {
    return undefined;
  }
  return revision;
}

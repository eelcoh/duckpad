// Decide which document text Elm receives before it can execute any cells.
// A desktop file supplies association; localStorage supplies crash recovery.
export function chooseStartup(recovered, restored) {
  const recoveryIsNewer =
    restored !== null &&
    recovered !== null &&
    recovered.content !== restored.content &&
    recovered.modified > restored.modified;

  return {
    saved: recoveryIsNewer ? recovered.content : (restored?.content ?? recovered?.content ?? null),
    associated: restored !== null,
    dirty: recoveryIsNewer,
  };
}

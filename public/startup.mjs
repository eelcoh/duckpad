// Decide what Elm receives before it can execute any cell.
//
// The rule this encodes: never run a document whose location is unknown. A
// desktop build that restored a real file association knows where relative
// data paths resolve and can open straight into the document. Anything else —
// a browser, or a desktop whose remembered file has moved — has content
// without a base directory, and goes to the home screen instead, where the
// reader can reconnect it or accept that it has no file.
export function chooseStartup(recovered, restored, recents, formerPath) {
  const recoveryIsNewer =
    restored !== null &&
    recovered !== null &&
    recovered.content !== restored.content &&
    recovered.modified > restored.modified;

  const associated = restored !== null;

  return {
    saved: recoveryIsNewer ? recovered.content : (restored?.content ?? recovered?.content ?? null),
    associated,
    dirty: recoveryIsNewer,

    // An associated document is the one case with somewhere definite to go.
    // The seeded example is deliberately not that: it is an action on the
    // home screen, not the document a reader lands in by default.
    home: !associated,
    formerPath: formerPath ?? null,
    recents: recents ?? [],
    now: Date.now(),
  };
}

// The recents index: pointers to documents, never copies of them.
//
// An entry carries a name, a location the host can act on, when it was last
// opened, and whether the recovery mirror is still holding edits for it. It
// carries no file contents, so losing the index loses nothing but convenience
// and the index can never drift into being a second, staler notebook.
//
// The two hosts point at a document differently. Under Tauri the key is an
// absolute path, and `read_file` both reads it and re-establishes the
// association — which is the whole point of reopening from here, since a
// relative data path is resolved against the document's directory. In a
// browser there is no path to keep: the File System Access API hands out
// handles, which survive a reload only in IndexedDB and only while their
// permission does. A browser without that API keeps no entries at all rather
// than listing documents it has no way to reopen.

const KEY = 'duckpad.recents';
const LIMIT = 8;

const tauri = () => window.__TAURI__;
const canHold = () => typeof window.showOpenFilePicker === 'function';

let notify = () => {};

/** Called with the whole index whenever it changes. */
export function onRecentsChanged(callback) {
  notify = callback;
}

export function listRecents() {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    // Storage disabled or holding something that is not an index. Starting
    // empty is correct: the index is convenience, and nothing depends on it.
    return [];
  }
}

function write(entries) {
  try {
    localStorage.setItem(KEY, JSON.stringify(entries.slice(0, LIMIT)));
  } catch {
    // Out of quota. The documents are still on disk; only the shortcut is
    // gone, so there is nothing to report and nothing to undo.
  }
  notify(listRecents());
}

/**
 * Record that a document was opened or saved.
 *
 * `key` identifies it to the host: a path under Tauri, a handle id in a
 * browser. Re-recording an existing key moves it to the front and refreshes
 * its timestamp rather than adding a duplicate.
 */
export function rememberRecent({ key, name, path, handle }) {
  if (!key) return;
  if (handle) holdHandle(key, handle);
  const rest = listRecents().filter((entry) => entry.key !== key);
  write([{ key, name, path: path ?? null, opened: Date.now(), unsaved: false, reachable: true }, ...rest]);
}

export function forgetRecent(key) {
  write(listRecents().filter((entry) => entry.key !== key));
  dropHandle(key);
}

/** Note that a document's edits are, or are no longer, only in the mirror. */
export function markUnsaved(key, unsaved) {
  if (!key) return;
  const entries = listRecents();
  const found = entries.find((entry) => entry.key === key);
  if (!found || found.unsaved === unsaved) return;
  found.unsaved = unsaved;
  write(entries);
}

function markUnreachable(key) {
  const entries = listRecents();
  const found = entries.find((entry) => entry.key === key);
  if (!found || found.reachable === false) return;
  found.reachable = false;
  write(entries);
}

/**
 * Reopen an entry, or locate it when the host can no longer reach it.
 *
 * Both come back shaped like any other open, so the caller cannot tell a
 * recent apart from a file the reader picked — which is what keeps this from
 * becoming a second, subtly different way to load a notebook.
 */
export async function openRecent(key, locate) {
  if (tauri()) {
    if (locate) return null;
    try {
      const content = await tauri().core.invoke('read_file', { path: key });
      rememberRecent({ key, name: basename(key), path: key });
      return { content, associated: true };
    } catch {
      // The file moved or went away. The entry stays, marked, so it can be
      // located rather than disappearing without explanation.
      markUnreachable(key);
      return null;
    }
  }

  if (locate) return null;

  const handle = await heldHandle(key);
  if (!handle) {
    markUnreachable(key);
    return null;
  }
  const granted = await handle.queryPermission({ mode: 'readwrite' });
  if (granted !== 'granted' && (await handle.requestPermission({ mode: 'readwrite' })) !== 'granted') {
    markUnreachable(key);
    return null;
  }
  rememberRecent({ key, name: handle.name, handle });
  return { content: await (await handle.getFile()).text(), associated: true, handle };
}

export function basename(path) {
  const parts = String(path).split(/[\\/]/);
  return parts[parts.length - 1] || path;
}

// Handles are structured-cloneable but not JSON, so they live in IndexedDB
// beside the index rather than in it. A browser that cannot hold one keeps no
// entry, so the list never offers something it cannot open.

const DB = 'duckpad-handles';
const STORE = 'handles';

function withStore(mode, run) {
  if (!canHold() || !window.indexedDB) return Promise.resolve(null);
  return new Promise((resolve) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onerror = () => resolve(null);
    request.onsuccess = () => {
      const db = request.result;
      const tx = db.transaction(STORE, mode);
      const done = run(tx.objectStore(STORE));
      tx.oncomplete = () => {
        db.close();
        resolve(done ? done.result ?? null : null);
      };
      tx.onerror = () => {
        db.close();
        resolve(null);
      };
    };
  });
}

function holdHandle(key, handle) {
  return withStore('readwrite', (store) => store.put(handle, key));
}

function heldHandle(key) {
  return withStore('readonly', (store) => store.get(key));
}

function dropHandle(key) {
  return withStore('readwrite', (store) => store.delete(key));
}

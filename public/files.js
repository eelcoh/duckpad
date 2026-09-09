// Reading and writing notebooks, on whichever of the two hosts is running.
//
// A browser reaches disk through the File System Access API, which only
// Chromium implements, and falls back to a download plus an `<input
// type="file">`. A WebKit webview does nothing with any of the three, which is
// why Open, Save and Export were all inert in the desktop build until this
// existed.
//
// Under Tauri the native picker chooses a path and a Rust command moves the
// bytes. Everything else is unchanged, and the browser build never loads any
// of the Tauri branch.

const tauri = () => window.__TAURI__;

const NOTEBOOK = { name: 'duckpad notebook', extensions: ['md'] };
const PAGE = { name: 'Web page', extensions: ['html'] };
let notebookHandle = null;

/** The notebook the reader chose, or null if they cancelled. */
export async function openNotebook() {
  if (tauri()) {
    const path = await tauri().dialog.open({ multiple: false, filters: [NOTEBOOK] });
    if (!path) return null;
    const content = await tauri().core.invoke('read_file', { path });
    return { content, associated: true, entry: entryForPath(path) };
  }

  if (window.showOpenFilePicker) {
    try {
      const [handle] = await window.showOpenFilePicker({
        types: [{ description: NOTEBOOK.name, accept: { 'text/markdown': ['.md'] } }],
      });
      notebookHandle = handle;
      return {
        content: await (await handle.getFile()).text(),
        associated: true,
        entry: entryForHandle(handle),
      };
    } catch (err) {
      if (err && err.name === 'AbortError') return null;
      throw err;
    }
  }

  const content = await pickWithInput();
  return content === null ? null : { content, associated: false };
}

export async function saveNotebook(name, content, saveAs) {
  if (tauri()) {
    if (!saveAs) {
      await tauri().core.invoke('write_current_file', { contents: content });
      return { associated: true };
    }
    const path = await tauri().dialog.save({ defaultPath: name, filters: [NOTEBOOK] });
    if (!path) return { cancelled: true };
    await tauri().core.invoke('write_file', { path, contents: content });
    return { associated: true, entry: entryForPath(path) };
  }

  if (window.showSaveFilePicker) {
    try {
      let handle = notebookHandle;
      if (saveAs || !handle) {
        handle = await window.showSaveFilePicker({
          suggestedName: name,
          types: [{ description: NOTEBOOK.name, accept: { 'text/markdown': ['.md'] } }],
        });
      }
      const writable = await handle.createWritable();
      await writable.write(content);
      await writable.close();
      notebookHandle = handle;
      return { associated: true, entry: entryForHandle(handle) };
    } catch (err) {
      if (err && err.name === 'AbortError') return { cancelled: true };
      throw err;
    }
  }

  download(name, content, 'text/markdown');
  return { associated: false };
}

// What the recents index should record about a document just opened or saved.
//
// A path is its own key, because that is exactly what reopening it needs. A
// browser handle has no path to show, so it gets a key of its own and the
// handle rides along to be held in IndexedDB; the entry then shows a name and
// a time and honestly offers no location.

function entryForPath(path) {
  const parts = String(path).split(/[\\/]/);
  return { key: path, name: parts[parts.length - 1] || path, path };
}

function entryForHandle(handle) {
  return { key: `handle:${handle.name}`, name: handle.name, handle };
}

export async function clearNotebook() {
  notebookHandle = null;
  if (tauri()) await tauri().core.invoke('clear_notebook');
}

export async function saveExport(name, html) {
  return saveText(name, html, PAGE, 'text/html');
}

async function saveText(name, content, filter, mime) {
  if (tauri()) {
    const path = await tauri().dialog.save({ defaultPath: name, filters: [filter] });
    if (!path) return;
    await tauri().core.invoke('write_export', { path, contents: content });
    return;
  }

  if (window.showSaveFilePicker) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: name,
        types: [{ description: filter.name, accept: { [mime]: filter.extensions.map((e) => '.' + e) } }],
      });
      const writable = await handle.createWritable();
      await writable.write(content);
      await writable.close();
      return;
    } catch (err) {
      // A cancelled picker is not a failure worth reporting.
      if (err && err.name === 'AbortError') return;
    }
  }

  download(name, content, mime);
}

function download(name, content, mime) {
  const url = URL.createObjectURL(new Blob([content], { type: mime }));
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}

function pickWithInput() {
  return new Promise((resolve, reject) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.md,text/markdown';
    input.onchange = () => {
      const file = input.files && input.files[0];
      if (!file) return resolve(null);
      file.text().then(resolve, reject);
    };
    input.click();
  });
}

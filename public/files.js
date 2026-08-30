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

/** The notebook the reader chose, or null if they cancelled. */
export async function openNotebook() {
  if (tauri()) {
    const path = await tauri().dialog.open({ multiple: false, filters: [NOTEBOOK] });
    if (!path) return null;
    return tauri().core.invoke('read_file', { path });
  }

  if (window.showOpenFilePicker) {
    try {
      const [handle] = await window.showOpenFilePicker({
        types: [{ description: NOTEBOOK.name, accept: { 'text/markdown': ['.md'] } }],
      });
      return (await handle.getFile()).text();
    } catch (err) {
      if (err && err.name === 'AbortError') return null;
      throw err;
    }
  }

  return pickWithInput();
}

export async function saveNotebook(name, content) {
  return saveText(name, content, NOTEBOOK, 'text/markdown');
}

export async function saveExport(name, html) {
  return saveText(name, html, PAGE, 'text/html');
}

async function saveText(name, content, filter, mime) {
  if (tauri()) {
    const path = await tauri().dialog.save({ defaultPath: name, filters: [filter] });
    if (!path) return;
    await tauri().core.invoke('write_file', { path, contents: content });
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

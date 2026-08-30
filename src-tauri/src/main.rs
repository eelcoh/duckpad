// The desktop shell.
//
// Rust does as little as possible: the notebook still runs entirely in the
// page — DuckDB in WebAssembly, the compiler in Elm, the charts in Vega — and
// this opens a window onto it.
//
// The exception is files. A browser reaches disk through the File System
// Access API, which is Chromium-only, or by falling back to a download and an
// `<input type="file">`, neither of which a WebKit webview does anything with.
// So the two file operations are commands here instead, paired with the
// native picker. Reading and writing are deliberately not the `fs` plugin:
// these paths come straight from a dialog the reader just used, which is a
// clearer permission story than a filesystem scope.

#[tauri::command]
fn read_file(path: String) -> Result<String, String> {
    std::fs::read_to_string(&path).map_err(|e| e.to_string())
}

#[tauri::command]
fn write_file(path: String, contents: String) -> Result<(), String> {
    std::fs::write(&path, contents).map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![read_file, write_file])
        .run(tauri::generate_context!())
        .expect("duckpad failed to start");
}

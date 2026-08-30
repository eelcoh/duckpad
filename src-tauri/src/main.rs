// The desktop shell, and deliberately nothing more.
//
// This is a spike: it answers whether the notebook runs outside Chromium at
// all. Everything still happens in the page — DuckDB in WebAssembly, the
// compiler in Elm, the charts in Vega — and Rust does no work beyond opening
// a window onto it. If the answer is yes, moving DuckDB native becomes worth
// considering; if it is no, that is worth knowing before any of it is written.

fn main() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("duckpad failed to start");
}

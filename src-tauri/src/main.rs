use duckdb::Connection;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Instant, UNIX_EPOCH},
};
use tauri::{path::BaseDirectory, Manager};

struct Database {
    connection: Mutex<Connection>,
    document_path: Mutex<Option<PathBuf>>,
    notebook_dir: Mutex<Option<PathBuf>>,
    bundled_resource_dir: PathBuf,
    excel_extension: PathBuf,
    association_file: PathBuf,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Materialize {
    cell_id: String,
    sql: String,
    order_significant: bool,
    row_limit: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Source {
    cell_id: String,
    format: String,
    uri: String,
    options: String,
}

#[derive(Serialize)]
struct Described {
    #[serde(rename = "originalName")]
    original_name: String,
    name: String,
    #[serde(rename = "type")]
    sql_type: String,
    nullable: bool,
}

#[derive(Serialize)]
struct Restored {
    content: String,
    modified: u64,
}

#[tauri::command(async)]
fn read_file(path: String, state: tauri::State<'_, Database>) -> Result<String, String> {
    let path = PathBuf::from(path);
    let contents = std::fs::read_to_string(&path).map_err(err)?;
    associate_document(&path, &state)?;
    Ok(contents)
}

#[tauri::command(async)]
fn write_file(
    path: String,
    contents: String,
    state: tauri::State<'_, Database>,
) -> Result<(), String> {
    let path = PathBuf::from(path);
    std::fs::write(&path, contents).map_err(err)?;
    associate_document(&path, &state)?;
    Ok(())
}

#[tauri::command(async)]
fn restore_file(state: tauri::State<'_, Database>) -> Result<Option<Restored>, String> {
    let remembered = match std::fs::read_to_string(&state.association_file) {
        Ok(path) => PathBuf::from(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(err(error)),
    };
    match std::fs::read_to_string(&remembered) {
        Ok(content) => {
            let modified = std::fs::metadata(&remembered)
                .and_then(|metadata| metadata.modified())
                .and_then(|time| time.duration_since(UNIX_EPOCH).map_err(std::io::Error::other))
                .map_err(err)?
                .as_millis() as u64;
            associate_document(&remembered, &state)?;
            Ok(Some(Restored { content, modified }))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            forget_document(&state)?;
            Ok(None)
        }
        Err(error) => Err(err(error)),
    }
}

fn associate_document(path: &Path, state: &Database) -> Result<(), String> {
    *state.document_path.lock().map_err(err)? = Some(path.to_path_buf());
    *state.notebook_dir.lock().map_err(err)? = path.parent().map(Path::to_path_buf);
    if let Some(directory) = state.association_file.parent() {
        std::fs::create_dir_all(directory).map_err(err)?;
    }
    std::fs::write(
        &state.association_file,
        path.to_string_lossy().as_bytes(),
    )
    .map_err(err)
}

fn forget_document(state: &Database) -> Result<(), String> {
    *state.document_path.lock().map_err(err)? = None;
    *state.notebook_dir.lock().map_err(err)? = None;
    match std::fs::remove_file(&state.association_file) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(err(error)),
    }
}

#[tauri::command(async)]
fn write_current_file(contents: String, state: tauri::State<'_, Database>) -> Result<(), String> {
    let path = state
        .document_path
        .lock()
        .map_err(err)?
        .clone()
        .ok_or_else(|| "this notebook has no file yet".to_string())?;
    std::fs::write(path, contents).map_err(err)
}

#[tauri::command(async)]
fn write_export(path: String, contents: String) -> Result<(), String> {
    std::fs::write(path, contents).map_err(err)
}

#[tauri::command(async)]
fn clear_notebook(state: tauri::State<'_, Database>) -> Result<(), String> {
    forget_document(&state)
}

// DuckDB work must never run on Tauri's main thread: opening the tutorial
// dispatches several cells in sequence, and an unoptimised development build
// can otherwise make the whole window appear frozen while they finish.
#[tauri::command(async)]
fn db_boot(state: tauri::State<'_, Database>) -> Result<Value, String> {
    state
        .connection
        .lock()
        .map_err(err)?
        .query_row("SELECT 1", [], |_| Ok(()))
        .map_err(err)?;
    Ok(json!({ "ok": true, "schema": [] }))
}

#[tauri::command(async)]
fn db_load_source(request: Source, state: tauri::State<'_, Database>) -> Result<Value, String> {
    let started = Instant::now();
    let reader = match request.format.as_str() {
        "csv" => "read_csv_auto",
        "parquet" => "read_parquet",
        "json" => "read_json_auto",
        "xlsx" => "read_xlsx",
        value => return Err(format!("unknown source format: {value}")),
    };
    let location = resolve_source(&request.uri, &state)?;
    let name = quote_ident(&request.cell_id);
    let connection = state.connection.lock().map_err(err)?;
    if request.format == "xlsx" {
        load_excel(&connection, &state.excel_extension)?;
    }
    connection
        .execute_batch(&format!(
            "CREATE OR REPLACE VIEW {name} AS SELECT * FROM {reader}({}{})",
            quote_literal(&location),
            request.options
        ))
        .map_err(err)?;
    let original_names = original_column_names(&connection, reader, &location, &request.options);
    outcome(&connection, &request.cell_id, &name, 200, false, started, original_names.as_deref())
}

#[tauri::command(async)]
fn db_materialize(request: Materialize, state: tauri::State<'_, Database>) -> Result<Value, String> {
    let started = Instant::now();
    let name = quote_ident(&request.cell_id);
    let connection = state.connection.lock().map_err(err)?;
    connection
        .execute_batch(&format!(
            "CREATE OR REPLACE TEMP TABLE {name} AS {}",
            request.sql
        ))
        .map_err(err)?;
    outcome(&connection, &request.cell_id, &name, request.row_limit, request.order_significant, started, None)
}

#[tauri::command(async)]
fn db_drop_table(cell_id: String, state: tauri::State<'_, Database>) -> Result<(), String> {
    let connection = state.connection.lock().map_err(err)?;
    let name = quote_ident(&cell_id);
    for kind in ["VIEW", "TABLE"] {
        let _ = connection.execute_batch(&format!("DROP {kind} IF EXISTS {name}"));
    }
    Ok(())
}

fn resolve_source(uri: &str, state: &tauri::State<'_, Database>) -> Result<String, String> {
    if uri.starts_with("https://") || uri.starts_with("http://localhost") || uri.starts_with("http://127.0.0.1") {
        return Ok(uri.into());
    }
    let base = state.notebook_dir.lock().map_err(err)?;
    Ok(resolve_source_path(
        uri,
        base.as_deref(),
        &state.bundled_resource_dir,
    )
        .to_string_lossy()
        .into_owned())
}

fn resolve_source_path(uri: &str, notebook_dir: Option<&Path>, bundled_resource_dir: &Path) -> PathBuf {
    let path = PathBuf::from(uri);
    if path.is_absolute() {
        return path;
    }
    match notebook_dir {
        Some(directory) => directory.join(path),
        None => bundled_resource_dir.join(path),
    }
}

fn outcome(connection: &Connection, cell_id: &str, name: &str, limit: usize, ordered: bool, started: Instant, original_names: Option<&[String]>) -> Result<Value, String> {
    let described = describe(connection, name, original_names)?;
    let columns: Vec<_> = described.iter().map(|c| json!({ "name": c.name, "type": c.sql_type })).collect();
    let row_count: i64 = connection.query_row(&format!("SELECT count(*) FROM {name}"), [], |r| r.get(0)).map_err(err)?;
    let rows = rows_json(connection, name, &described, limit)?;
    let order = if ordered { "rn" } else { "rt" };
    let hash: String = connection.query_row(&format!(
        "SELECT md5(coalesce(string_agg(rt, chr(10) ORDER BY {order}), '')) FROM (SELECT row_number() OVER () rn, CAST(t AS VARCHAR) rt FROM {name} t)"
    ), [], |r| r.get(0)).map_err(err)?;
    Ok(json!({ "ok": true, "cellId": cell_id, "columns": columns, "described": described,
        "rows": rows, "rowCount": row_count, "truncated": row_count > limit as i64,
        "hash": hash, "millis": started.elapsed().as_secs_f64() * 1000.0 }))
}

fn describe(connection: &Connection, name: &str, original_names: Option<&[String]>) -> Result<Vec<Described>, String> {
    let mut statement = connection.prepare(&format!("DESCRIBE {name}")).map_err(err)?;
    let raw = statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .map_err(err)?.collect::<Result<Vec<_>, _>>().map_err(err)?;
    raw.into_iter().enumerate().map(|(index, (column, sql_type))| {
        let nulls: i64 = connection.query_row(&format!(
            "SELECT count(*) - count({}) FROM (SELECT * FROM {name} LIMIT 200000)", quote_ident(&column)
        ), [], |r| r.get(0)).map_err(err)?;
        let original_name = original_names.and_then(|names| names.get(index)).cloned().unwrap_or_else(|| column.clone());
        Ok(Described { original_name, name: column, sql_type, nullable: nulls > 0 })
    }).collect()
}

fn original_column_names(connection: &Connection, reader: &str, location: &str, options: &str) -> Option<Vec<String>> {
    if reader != "read_xlsx" || !options.contains("normalize_names=true") {
        return None;
    }
    let raw_options = options.replace("normalize_names=true", "normalize_names=false");
    let sql = format!("DESCRIBE SELECT * FROM {reader}({}{raw_options})", quote_literal(location));
    let mut statement = connection.prepare(&sql).ok()?;
    statement.query_map([], |row| row.get::<_, String>(0)).ok()?.collect::<Result<Vec<_>, _>>().ok()
}

fn rows_json(connection: &Connection, name: &str, columns: &[Described], limit: usize) -> Result<Value, String> {
    let fields = columns.iter().map(|c| {
        let column = quote_ident(&c.name);
        let upper = c.sql_type.to_ascii_uppercase();
        let value = if upper.starts_with("TIMESTAMP") || upper == "DATE" {
            format!("to_json(epoch_ms({column}))")
        } else if matches!(upper.as_str(), "BIGINT" | "UBIGINT" | "HUGEINT" | "UHUGEINT") {
            format!("CASE WHEN abs({column}) <= 9007199254740991 THEN to_json({column}) ELSE to_json(CAST({column} AS VARCHAR)) END")
        } else { format!("to_json({column})") };
        format!("{}, {value}", quote_literal(&c.name))
    }).collect::<Vec<_>>().join(", ");
    let encoded: String = connection.query_row(&format!(
        "SELECT coalesce(CAST(json_group_array(json_object({fields})) AS VARCHAR), '[]') FROM (SELECT * FROM {name} LIMIT {limit})"
    ), [], |r| r.get(0)).map_err(err)?;
    serde_json::from_str(&encoded).map_err(err)
}

fn quote_ident(value: &str) -> String { format!("\"{}\"", value.replace('"', "\"\"")) }
fn quote_literal(value: &str) -> String { format!("'{}'", value.replace('\'', "''")) }
fn err(error: impl std::fmt::Display) -> String { error.to_string() }

fn load_excel(connection: &Connection, extension: &Path) -> Result<(), String> {
    connection
        .execute_batch(&format!(
            "LOAD {}",
            quote_literal(&extension.to_string_lossy())
        ))
        .map_err(err)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_outcome_matches_the_browser_contract() {
        let connection = Connection::open_in_memory().unwrap();
        connection.execute_batch(
            "CREATE TABLE result AS SELECT 7 AS n, 9007199254740992::BIGINT AS wide, \
             TIMESTAMP '2024-01-02 03:04:05' AS happened, NULL::VARCHAR AS note",
        ).unwrap();

        let original_names = vec!["Number".into(), "Wide number".into(), "When".into(), "Note".into()];
        let value = outcome(&connection, "cell-1", "result", 200, true, Instant::now(), Some(&original_names)).unwrap();
        assert_eq!(value["ok"], true);
        assert_eq!(value["cellId"], "cell-1");
        assert_eq!(value["rowCount"], 1);
        assert_eq!(value["truncated"], false);
        assert_eq!(value["rows"][0]["n"], 7);
        assert_eq!(value["rows"][0]["wide"], "9007199254740992");
        assert_eq!(value["rows"][0]["happened"], 1704164645000_i64);
        assert!(value["rows"][0]["note"].is_null());
        assert_eq!(value["described"][3]["nullable"], true);
        assert_eq!(value["described"][1]["originalName"], "Wide number");
        assert_eq!(value["hash"].as_str().unwrap().len(), 32);
    }

    #[test]
    fn sql_names_and_values_are_escaped() {
        assert_eq!(quote_ident("a\"b"), "\"a\"\"b\"");
        assert_eq!(quote_literal("it's"), "'it''s'");
    }

    #[test]
    fn bundled_sources_and_opened_notebooks_have_distinct_bases() {
        let resources = Path::new("/app/resources");
        assert_eq!(
            resolve_source_path("data/orders.csv", None, resources),
            Path::new("/app/resources/data/orders.csv")
        );
        assert_eq!(
            resolve_source_path("data/orders.csv", Some(Path::new("/work/report")), resources),
            Path::new("/work/report/data/orders.csv")
        );
    }

    #[test]
    fn packaged_excel_extension_reads_the_fixture_offline() {
        let connection = Connection::open_in_memory().unwrap();
        let platform: String = connection
            .query_row("SELECT platform FROM pragma_platform()", [], |row| row.get(0))
            .unwrap();
        let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
        let extension = manifest
            .join("resources/extensions/v1.5.5")
            .join(platform)
            .join("excel.duckdb_extension");
        load_excel(&connection, &extension).unwrap();

        let workbook = manifest.join("../public/data/workbook.xlsx");
        let count: i64 = connection
            .query_row(
                &format!(
                    "SELECT count(*) FROM read_xlsx({}, sheet='Forecast', range='A1:C4', header=true)",
                    quote_literal(&workbook.to_string_lossy())
                ),
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 3);
    }
}

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let bundled_resource_dir = app
                .path()
                .resolve(".", BaseDirectory::Resource)
                .map_err(err)?;
            let connection = Connection::open_in_memory().map_err(err)?;
            let (version, platform): (String, String) = connection
                .query_row(
                    "SELECT library_version, (SELECT platform FROM pragma_platform()) FROM pragma_version()",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .map_err(err)?;
            let excel_extension = bundled_resource_dir
                .join("extensions")
                .join(version)
                .join(platform)
                .join("excel.duckdb_extension");
            let association_file = app
                .path()
                .app_data_dir()
                .map_err(err)?
                .join("last-notebook");
            app.manage(Database {
                connection: Mutex::new(connection),
                document_path: Mutex::new(None),
                notebook_dir: Mutex::new(None),
                bundled_resource_dir,
                excel_extension,
                association_file,
            });
            Ok(())
        })
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            read_file,
            restore_file,
            write_file,
            write_current_file,
            write_export,
            clear_notebook,
            db_boot,
            db_load_source,
            db_materialize,
            db_drop_table
        ])
        .run(tauri::generate_context!())
        .expect("duckpad failed to start");
}

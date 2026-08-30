// Bridge between the Elm notebook shell and DuckDB-wasm.
//
// The Elm side owns the dependency graph, compiles the DSL, and decides what
// runs and in what order. This file knows nothing about cells beyond their
// names: it builds the base tables, reports their schema so the compiler has
// something to check against, materialises a query, and reports a content hash
// so the value cache can decide whether downstream work is needed.

import * as duckdb from 'https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.32.0/+esm';
import { exportStatic } from './export.js';
import { openNotebook, saveNotebook } from './files.js';

const PREVIEW_ROWS = 200;

// How many rows are sampled to learn which columns contain nulls, for formats
// that cannot say. Parquet can, and is handled separately.
const NULL_SAMPLE = 200000;

const READERS = {
  csv: 'read_csv_auto',
  parquet: 'read_parquet',
  json: 'read_json_auto',
};

let db = null;
let conn = null;

const STORAGE_KEY = 'duckpad.notebook';

const app = window.Elm.Main.init({
  node: document.getElementById('notebook'),
  flags: { saved: readSaved() },
});

// Browser storage can throw outright (private windows, blocked site data), so
// every access is guarded and a failure simply means starting fresh.
function readSaved() {
  try {
    return localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

// Elm owns the textarea's value, so replacing it after an Enter or Tab moves
// the caret to the end. The handler computed where it belongs; this puts it
// there, on the next frame, once Elm has actually rendered the new value.
app.ports.setCaret.subscribe(({ id, pos }) => {
  requestAnimationFrame(() => {
    const el = document.getElementById(id);
    if (!el) return;
    el.focus();
    el.setSelectionRange(pos, pos);
  });
});

app.ports.exportStatic.subscribe(exportStatic);

app.ports.persist.subscribe((content) => {
  try {
    localStorage.setItem(STORAGE_KEY, content);
  } catch {
    // Out of quota or storage disabled. The safety net is gone; the document
    // is still whatever the reader last saved to a file.
  }
});

app.ports.requestSave.subscribe(async ({ name, content }) => {
  try {
    await saveNotebook(name, content);
  } catch (err) {
    console.error('[duckpad] save failed', err);
  }
});

app.ports.requestOpen.subscribe(async () => {
  try {
    const text = await openNotebook();
    if (text !== null) app.ports.fileOpened.send({ ok: true, content: text });
  } catch (err) {
    app.ports.fileOpened.send({ ok: false, error: String(err) });
  }
});

app.ports.dropTable.subscribe(async (cellId) => {
  if (!conn) return;
  // A cell is a table if it was a query and a view if it was a source, and by
  // the time this runs the cell is gone and cannot say which.
  for (const kind of ['VIEW', 'TABLE']) {
    try {
      await conn.query(`DROP ${kind} IF EXISTS ${quoteIdent(cellId)}`);
    } catch {
      // Nothing of that kind under that name. Not worth reporting.
    }
  }
});

// Elm already restricts cell names to [a-z0-9_], but the quoting stays: the
// name reaches SQL as an identifier and should not depend on that guarantee
// holding forever.
function quoteIdent(name) {
  return '"' + String(name).replace(/"/g, '""') + '"';
}

function schemaOf(result) {
  return result.schema.fields.map((f) => ({
    name: f.name,
    type: String(f.type),
  }));
}

function plainRows(result) {
  return result.toArray().map((row) => {
    const out = {};
    for (const [key, value] of Object.entries(row.toJSON())) {
      out[key] = normalize(value);
    }
    return out;
  });
}

// Arrow hands back values JSON.stringify cannot represent. Converting here
// rather than in Elm keeps the port payload plain JSON, which is what lets the
// generic table view and a generated decoder read the same rows.
function normalize(value) {
  if (value === null || value === undefined) return null;

  if (typeof value === 'bigint') {
    // DuckDB's default integer is BIGINT, so this is the common path, not an
    // edge case. Past 2^53 a Number would quietly lie, so those become strings
    // and a typed decoder fails loudly instead of silently truncating.
    const asNumber = Number(value);
    return Number.isSafeInteger(asNumber) ? asNumber : value.toString();
  }

  if (value instanceof Date) return value.getTime();
  if (
    typeof value === 'string' ||
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return value;
  }
  if (ArrayBuffer.isView(value)) return Array.from(value, normalize);
  if (Array.isArray(value)) return value.map(normalize);
  if (typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = normalize(v);
    return out;
  }
  return String(value);
}

function cleanError(err) {
  const text = err && err.message ? err.message : String(err);
  return text.replace(/^Error:\s*/, '');
}

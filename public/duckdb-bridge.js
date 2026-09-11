// Bridge between the Elm notebook shell and DuckDB-wasm.
//
// The Elm side owns the dependency graph, compiles the DSL, and decides what
// runs and in what order. This file knows nothing about cells beyond their
// names: it builds the base tables, reports their schema so the compiler has
// something to check against, materialises a query, and reports a content hash
// so the value cache can decide whether downstream work is needed.

import * as duckdb from './vendor/duckdb.mjs';
import { exportStatic } from './export.js';
import { clearNotebook, openNotebook, saveNotebook } from './files.js';
import { chooseStartup } from './startup.mjs';
import * as recents from './recents.mjs';
import { install as installZoom } from './zoom.mjs';

const PREVIEW_ROWS = 200;
const native = () => window.__TAURI__ && window.__TAURI__.core;

// How many rows are sampled to learn which columns contain nulls, for formats
// that cannot say. Parquet can, and is handled separately.
const NULL_SAMPLE = 200000;

const READERS = {
  csv: 'read_csv_auto',
  parquet: 'read_parquet',
  json: 'read_json_auto',
  xlsx: 'read_xlsx',
};

let db = null;
let conn = null;
let excelLoaded = false;

const STORAGE_KEY = 'duckpad.notebook';
const STORAGE_TIME_KEY = 'duckpad.notebook.modified';
const FORMER_PATH_KEY = 'duckpad.notebook.formerPath';

const recovered = readSaved();
const startup = await restoreDocument();
const restored = startup.restored ?? null;

// Where a recovery copy came from, when startup found the remembered file
// gone. Rust reports it once, on the start that discovers the loss; keeping
// it means a second start still says the file moved rather than implying the
// edits were never saved. It is cleared as soon as the copy stops being
// orphaned — which is any successful open or save.
const formerPath = rememberFormerPath(startup.formerPath) ?? readFormerPath();

const app = window.Elm.Main.init({
  node: document.getElementById('notebook'),
  flags: chooseStartup(recovered, restored, recents.listRecents(), formerPath),
});

recents.onRecentsChanged((entries) => app.ports.recentsChanged.send(entries));

app.ports.forgetRecent.subscribe((key) => recents.forgetRecent(key));

// Reopening a recent goes out through the same port an ordinary open returns
// on, so Elm has one way to receive a document rather than two.
app.ports.openRecent.subscribe(async ({ key, locate }) => {
  try {
    const opened = locate ? await openNotebook() : await recents.openRecent(key, false);
    if (opened === null) {
      // A cancelled picker is not a failure; an unreachable entry is, and the
      // entry has already marked itself so the list can offer Locate.
      if (!locate) {
        app.ports.fileOpened.send({
          ok: false,
          error: 'That notebook is no longer where it was. Use Locate to point at it again.',
        });
      }
      return;
    }
    if (locate && key) recents.forgetRecent(key);
    clearFormerPath();
    app.ports.fileOpened.send({ ok: true, ...opened });
  } catch (error) {
    app.ports.fileOpened.send({ ok: false, error: String(error) });
  }
});

// Desktop restores the last real document before Elm schedules any data cell,
// which gives relative paths their notebook directory from the first query.
// Browser recovery remains unassociated because a stored string is not a file
// handle and must never pretend that it can be overwritten.
async function restoreDocument() {
  if (!native()) return {};
  try {
    return (await native().invoke('restore_file')) ?? {};
  } catch (error) {
    console.warn('[duckpad] could not restore the last document', error);
    return {};
  }
}

function readFormerPath() {
  try {
    return localStorage.getItem(FORMER_PATH_KEY);
  } catch {
    return null;
  }
}

function rememberFormerPath(path) {
  if (!path) return null;
  try {
    localStorage.setItem(FORMER_PATH_KEY, path);
  } catch {
    // Only the second start loses the detail; this one still has the path.
  }
  return path;
}

// A document that opened or saved is no longer an orphaned recovery copy, so
// the hint has done its job and must not outlive it into an unrelated start.
function clearFormerPath() {
  try {
    localStorage.removeItem(FORMER_PATH_KEY);
  } catch {
    // Nothing to do: the hint is cosmetic and a stale one is not harmful.
  }
}

// Browser storage can throw outright (private windows, blocked site data), so
// every access is guarded and a failure simply means starting fresh.
function readSaved() {
  try {
    const content = localStorage.getItem(STORAGE_KEY);
    if (content === null) return null;
    return { content, modified: Number(localStorage.getItem(STORAGE_TIME_KEY) || 0) };
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

installZoom();

app.ports.exportStatic.subscribe(exportStatic);

app.ports.persist.subscribe((content) => {
  try {
    localStorage.setItem(STORAGE_KEY, content);
    localStorage.setItem(STORAGE_TIME_KEY, String(Date.now()));
  } catch {
    // Out of quota or storage disabled. The safety net is gone; the document
    // is still whatever the reader last saved to a file.
  }
});

// Saving and opening go through files.js, which knows the difference between
// a browser and the desktop shell. The File System Access API is Chromium
// only, and the webview Tauri uses on Linux has neither it nor a working
// download, so on the desktop these become calls into Rust.
app.ports.requestSave.subscribe(async ({ name, content, revision, saveAs }) => {
  try {
    const result = await saveNotebook(name, content, saveAs);
    if (result.entry) recents.rememberRecent(result.entry);
    if (!result.cancelled) clearFormerPath();
    app.ports.fileSaved.send({ ok: true, revision, ...result });
  } catch (err) {
    app.ports.fileSaved.send({ ok: false, revision, error: String(err) });
  }
});

app.ports.requestOpen.subscribe(async () => {
  try {
    const opened = await openNotebook();
    if (opened === null) return;
    if (opened.entry) recents.rememberRecent(opened.entry);
    clearFormerPath();
    app.ports.fileOpened.send({ ok: true, ...opened });
  } catch (err) {
    app.ports.fileOpened.send({ ok: false, error: String(err) });
  }
});

// Everything DuckDB needs is beside the page, so the worker is an ordinary
// same-origin script rather than a blob wrapping importScripts of a CDN URL.
// selectBundle still chooses between them: it tests for exception handling
// support and picks the build the browser can actually run.
const BUNDLES = {
  mvp: {
    mainModule: new URL('./vendor/duckdb-mvp.wasm', import.meta.url).href,
    mainWorker: new URL('./vendor/duckdb-browser-mvp.worker.js', import.meta.url).href,
  },
  eh: {
    mainModule: new URL('./vendor/duckdb-eh.wasm', import.meta.url).href,
    mainWorker: new URL('./vendor/duckdb-browser-eh.worker.js', import.meta.url).href,
  },
};

// A boot that fails is reported; a boot that hangs has to be reported too.
// The desktop build loads DuckDB from a CDN and spawns its worker from a blob
// URL, and either can sit there forever rather than reject, which leaves the
// notebook in "booting" with every button greyed and nothing to explain why.
const BOOT_TIMEOUT_MS = 30000;

Promise.race([
  boot(),
  new Promise((_, reject) =>
    setTimeout(
      () => reject(new Error(`DuckDB did not start within ${BOOT_TIMEOUT_MS / 1000}s`)),
      BOOT_TIMEOUT_MS
    )
  ),
])
  .then(() => app.ports.dbReady.send({ ok: true, schema: [] }))
  .catch((err) => app.ports.dbReady.send({ ok: false, error: String(err && err.message || err) }));

async function boot() {
  if (native()) {
    const ready = await native().invoke('db_boot');
    if (!ready.ok) throw new Error(ready.error || 'native DuckDB did not start');
    return;
  }
  const bundle = await duckdb.selectBundle(BUNDLES);
  db = new duckdb.AsyncDuckDB(
    new duckdb.ConsoleLogger(duckdb.LogLevel.WARNING),
    new Worker(bundle.mainWorker)
  );
  await db.instantiate(bundle.mainModule, bundle.pthreadWorker);

  conn = await db.connect();

  // Warm the engine before reporting ready. A fresh DuckDB does a lot of lazy
  // setup on its first real query, and without this that cost lands on
  // whichever cell happens to run first, which reads as "this cell is slow"
  // rather than "the database was still starting".
  await conn.query('SELECT 1');
}


// Timing breakdown for one cell, logged rather than shown: it is for working
// out where a slow load went, not something a reader needs.
function stopwatch(label) {
  const started = performance.now();
  let last = started;
  const phases = {};
  return {
    lap(name) {
      const now = performance.now();
      phases[name] = Math.round(now - last);
      last = now;
    },
    done() {
      const total = performance.now() - started;
      console.debug(`[duckpad] ${label} ${Math.round(total)}ms`, phases);
      return total;
    },
  };
}

// A source becomes a view, not a materialised table.
//
// A source is a reference to external data, not a computed value, and the
// difference is load-bearing: a view lets DuckDB push filters and column
// pruning down into the file, so a query over a remote Parquet fetches the
// byte ranges it needs instead of the whole thing. Materialising it here would
// pull every row into wasm memory and make the range requests pointless.
app.ports.loadSource.subscribe(async ({ cellId, format, uri, options }) => {
  if (native()) {
    try {
      app.ports.queryOutcome.send(await native().invoke('db_load_source', {
        request: { cellId, format, uri, options },
      }));
    } catch (err) {
      app.ports.queryOutcome.send({ ok: false, cellId, error: cleanError(err) });
    }
    return;
  }
  const clock = stopwatch(`source ${cellId}`);
  const name = quoteIdent(cellId);
  const reader = READERS[format];
  try {
    if (!reader) throw new Error(`unknown source format: ${format}`);
    if (format === 'xlsx') await ensureExcel();

    // Registered under a name of our own, so the URI never reaches SQL.
    const vfsName = `source_${cellId}.${format}`;
    const absolute = new URL(uri, window.location.href).href;
    await db.registerFileURL(vfsName, absolute, duckdb.DuckDBDataProtocol.HTTP, false);
    clock.lap('register');

    await conn.query(
      `CREATE OR REPLACE VIEW ${name} AS SELECT * FROM ${reader}('${vfsName}'${options})`
    );
    clock.lap('view');

    const originalNames = await originalColumnNames(format, reader, vfsName, options);
    const described = await describe(name, format, vfsName, originalNames);
    clock.lap('describe');

    const counted = plainRows(await conn.query(`SELECT count(*) AS n FROM ${name}`))[0];
    const rowCount = Number(counted.n);
    clock.lap('count');

    const preview = await conn.query(`SELECT * FROM ${name} LIMIT ${PREVIEW_ROWS}`);
    const rows = plainRows(preview);
    clock.lap('preview');

    app.ports.queryOutcome.send({
      ok: true,
      cellId,
      columns: schemaOf(preview),
      described,
      rows,
      rowCount,
      truncated: rowCount > rows.length,

      // A source's identity is where it points, not what is behind it: the
      // notebook does not refetch to find out whether a remote file changed.
      // The row count rides along so that a file which grew or shrank does
      // invalidate everything downstream, which is cheap to know for Parquet
      // and free for anything already read.
      hash: `${format}|${absolute}|${rowCount}`,
      millis: clock.done(),
    });
  } catch (err) {
    app.ports.queryOutcome.send({ ok: false, cellId, error: cleanError(err) });
  }
});

// Extension autoload normally reaches extensions.duckdb.org. Point it at the
// signed copy shipped with duckpad instead, so opening a local workbook does
// not quietly make the desktop app depend on the network.
async function ensureExcel() {
  if (excelLoaded) return;
  const repository = new URL('./vendor/extensions/', window.location.href).href;
  await conn.query(`SET custom_extension_repository = '${repository.replaceAll("'", "''")}'`);
  await conn.query('LOAD excel');
  excelLoaded = true;
}

// The compiler needs to know which columns exist, what they hold, and which
// can be absent.
//
// `information_schema` is no help for the last part: nothing here carries NOT
// NULL constraints, so every column reports itself as nullable and the row
// type would drown in Maybe. What the notebook actually wants to know is
// whether a column *does* contain nulls, which is a question about the data.
async function describe(name, format, vfsName, originalNames = null) {
  const described = plainRows(await conn.query(`DESCRIBE ${name}`));

  const nulls =
    (format === 'parquet' ? await nullsFromParquet(vfsName) : null) ||
    (await nullsBySampling(name, described));

  return described.map((c, index) => ({
    originalName: originalNames?.[index] || c.column_name,
    name: c.column_name,
    type: c.column_type,
    nullable: Number(nulls[c.column_name] || 0) > 0,
  }));
}

// Normalized Excel names replace the workbook headings in the view schema.
// DESCRIBE the same reader with normalization disabled to recover those
// headings; this reads metadata/header rows, not the worksheet into a table.
async function originalColumnNames(format, reader, vfsName, options) {
  if (format !== 'xlsx' || !/normalize_names\s*=\s*true/i.test(options)) return null;
  try {
    const rawOptions = options.replace(/normalize_names\s*=\s*true/i, 'normalize_names=false');
    const rows = plainRows(
      await conn.query(`DESCRIBE SELECT * FROM ${reader}('${vfsName}'${rawOptions})`)
    );
    return rows.map((column) => column.column_name);
  } catch {
    // The inferred schema is still useful if a particular extension version
    // cannot perform the metadata-only second describe.
    return null;
  }
}

// Parquet already knows. Every column chunk carries a null count in the file
// footer, so the answer is exact for the whole file and costs one metadata
// read instead of a scan — which matters most for exactly the files where
// scanning would hurt.
async function nullsFromParquet(vfsName) {
  try {
    const rows = plainRows(
      await conn.query(
        `SELECT path_in_schema AS column_name, sum(stats_null_count)::BIGINT AS nulls
         FROM parquet_metadata('${vfsName}')
         GROUP BY path_in_schema`
      )
    );
    return Object.fromEntries(rows.map((r) => [r.column_name, Number(r.nulls)]));
  } catch {
    // Statistics are optional in the format, and a writer may omit them.
    return null;
  }
}

// Everything else has to be counted. Capped, because a source is a view over
// a file that may be remote: scanning all of it to learn which columns can be
// absent would defeat reading it a page at a time. A column whose only nulls
// lie past the cap shows as non-nullable and renders as `?`, which is visible
// rather than silent.
async function nullsBySampling(name, described) {
  const counts = described
    .map((c) => `count(*) - count(${quoteIdent(c.column_name)}) AS ${quoteIdent(c.column_name)}`)
    .join(', ');
  return plainRows(
    await conn.query(`SELECT ${counts} FROM (SELECT * FROM ${name} LIMIT ${NULL_SAMPLE})`)
  )[0];
}

app.ports.materialize.subscribe(async ({ cellId, sql, orderSignificant, rowLimit }) => {
  if (native()) {
    try {
      app.ports.queryOutcome.send(await native().invoke('db_materialize', {
        request: { cellId, sql, orderSignificant, rowLimit },
      }));
    } catch (err) {
      app.ports.queryOutcome.send({ ok: false, cellId, error: cleanError(err) });
    }
    return;
  }
  const clock = stopwatch(`query ${cellId}`);
  const name = quoteIdent(cellId);
  try {
    // Cells are materialised rather than left as views: a cell in this model
    // *has a value*, and downstream cells reading a view would silently
    // re-execute their whole upstream chain on every query, which would make
    // the value cache meaningless. The cost is memory for intermediates,
    // which is acceptable at the file-sized scale this targets.
    await conn.query(`CREATE OR REPLACE TEMP TABLE ${name} AS (${sql})`);
    clock.lap('materialise');

    const stats = await conn.query(hashQuery(name, orderSignificant));
    const { n, h } = plainRows(stats)[0];
    clock.lap('hash');

    const preview = await conn.query(`SELECT * FROM ${name} LIMIT ${rowLimit}`);
    const rows = plainRows(preview);
    clock.lap('preview');

    // A materialised query result is local and has no file metadata, so
    // nullability is sampled — cheaply, since nothing has to be fetched.
    const described = await describe(name, null, null);
    clock.lap('describe');

    app.ports.queryOutcome.send({
      ok: true,
      cellId,
      columns: schemaOf(preview),
      described,
      rows,
      rowCount: Number(n),
      truncated: Number(n) > rows.length,
      hash: String(h),
      millis: clock.done(),
    });
  } catch (err) {
    app.ports.queryOutcome.send({ ok: false, cellId, error: cleanError(err) });
  }
});

// The content hash is computed inside DuckDB so the value cache never depends
// on pulling a whole result into JS.
//
// Which ordering the rows are folded in decides what the hash can notice.
// Sorting by the row text is deterministic under parallel execution but blind
// to a reordering, which is the right trade for a cell that never asked for an
// order. A cell that sorts or limits gets the row_number ordering instead, so
// rearranging its rows really does invalidate everything downstream. The
// compiler decides which of the two applies.
function hashQuery(name, orderSignificant) {
  const ordering = orderSignificant ? 'rn' : 'rt';
  return `
    SELECT count(*) AS n,
           md5(coalesce(string_agg(rt, chr(10) ORDER BY ${ordering}), '')) AS h
    FROM (SELECT row_number() OVER () AS rn, CAST(t AS VARCHAR) AS rt FROM ${name} t)`;
}

app.ports.dropTable.subscribe(async (cellId) => {
  if (native()) {
    try { await native().invoke('db_drop_table', { cellId }); } catch (err) { console.warn(err); }
    return;
  }
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

app.ports.clearNotebook.subscribe(async () => {
  // Saying a document has no file also retires any hint about where a file
  // used to be, or the next start would describe a situation that is over.
  clearFormerPath();
  try { await clearNotebook(); } catch (err) { console.warn(err); }
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

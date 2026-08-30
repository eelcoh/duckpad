// Bridge between the Elm notebook shell and DuckDB-wasm.
//
// The Elm side owns the dependency graph, compiles the DSL, and decides what
// runs and in what order. This file knows nothing about cells beyond their
// names: it builds the base tables, reports their schema so the compiler has
// something to check against, materialises a query, and reports a content hash
// so the value cache can decide whether downstream work is needed.

import * as duckdb from 'https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.32.0/+esm';
import { exportStatic } from './export.js';

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

// Saving prefers a real file handle so a reader can keep the notebook in a
// repository next to the data it queries. Where that API is missing the
// fallback is an ordinary download, which lands in the same place a browser
// puts everything else.
app.ports.requestSave.subscribe(async ({ name, content }) => {
  if (window.showSaveFilePicker) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: name,
        types: [{ description: 'duckpad notebook', accept: { 'text/markdown': ['.md'] } }],
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
  download(name, content);
});

function download(name, content) {
  const url = URL.createObjectURL(new Blob([content], { type: 'text/markdown' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}

app.ports.requestOpen.subscribe(async () => {
  try {
    const text = await pickFile();
    if (text !== null) app.ports.fileOpened.send({ ok: true, content: text });
  } catch (err) {
    app.ports.fileOpened.send({ ok: false, error: String(err) });
  }
});

function pickFile() {
  if (window.showOpenFilePicker) {
    return window
      .showOpenFilePicker({
        types: [{ description: 'duckpad notebook', accept: { 'text/markdown': ['.md'] } }],
      })
      .then(([handle]) => handle.getFile())
      .then((file) => file.text())
      .catch((err) => {
        if (err && err.name === 'AbortError') return null;
        throw err;
      });
  }

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

boot()
  .then(() => app.ports.dbReady.send({ ok: true, schema: [] }))
  .catch((err) => app.ports.dbReady.send({ ok: false, error: String(err) }));

async function boot() {
  const bundle = await duckdb.selectBundle(duckdb.getJsDelivrBundles());
  const workerUrl = URL.createObjectURL(
    new Blob([`importScripts("${bundle.mainWorker}");`], { type: 'text/javascript' })
  );
  const worker = new Worker(workerUrl);
  db = new duckdb.AsyncDuckDB(
    new duckdb.ConsoleLogger(duckdb.LogLevel.WARNING),
    worker
  );
  await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
  URL.revokeObjectURL(workerUrl);

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
  const clock = stopwatch(`source ${cellId}`);
  const name = quoteIdent(cellId);
  const reader = READERS[format];
  try {
    if (!reader) throw new Error(`unknown source format: ${format}`);

    // Registered under a name of our own, so the URI never reaches SQL.
    const vfsName = `source_${cellId}.${format}`;
    const absolute = new URL(uri, window.location.href).href;
    await db.registerFileURL(vfsName, absolute, duckdb.DuckDBDataProtocol.HTTP, false);
    clock.lap('register');

    await conn.query(
      `CREATE OR REPLACE VIEW ${name} AS SELECT * FROM ${reader}('${vfsName}'${options})`
    );
    clock.lap('view');

    const described = await describe(name, format, vfsName);
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

// The compiler needs to know which columns exist, what they hold, and which
// can be absent.
//
// `information_schema` is no help for the last part: nothing here carries NOT
// NULL constraints, so every column reports itself as nullable and the row
// type would drown in Maybe. What the notebook actually wants to know is
// whether a column *does* contain nulls, which is a question about the data.
async function describe(name, format, vfsName) {
  const described = plainRows(await conn.query(`DESCRIBE ${name}`));

  const nulls =
    (format === 'parquet' ? await nullsFromParquet(vfsName) : null) ||
    (await nullsBySampling(name, described));

  return described.map((c) => ({
    name: c.column_name,
    type: c.column_type,
    nullable: Number(nulls[c.column_name] || 0) > 0,
  }));
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

// Bridge between the Elm notebook shell and DuckDB-wasm.
//
// The Elm side owns the dependency graph and decides *what* runs and in what
// order. This file knows nothing about cells beyond their names: it
// materialises a query, reports a content hash so the value cache can decide
// whether downstream work is needed, and hands back a preview.

import * as duckdb from 'https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.32.0/+esm';

const PREVIEW_ROWS = 200;
const SEED_CSV = 'data/orders.csv';

let conn = null;

const app = window.Elm.Main.init({ node: document.getElementById('notebook') });

boot()
  .then(() => app.ports.dbReady.send({ ok: true }))
  .catch((err) => app.ports.dbReady.send({ ok: false, error: String(err) }));

async function boot() {
  const bundle = await duckdb.selectBundle(duckdb.getJsDelivrBundles());
  const workerUrl = URL.createObjectURL(
    new Blob([`importScripts("${bundle.mainWorker}");`], { type: 'text/javascript' })
  );
  const worker = new Worker(workerUrl);
  const db = new duckdb.AsyncDuckDB(
    new duckdb.ConsoleLogger(duckdb.LogLevel.WARNING),
    worker
  );
  await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
  URL.revokeObjectURL(workerUrl);

  conn = await db.connect();

  // The notebook's only data source for now. Registering the text makes it
  // visible to read_csv_auto under this name.
  const csv = await fetch(SEED_CSV).then((r) => r.text());
  await db.registerFileText('orders.csv', csv);
}

app.ports.materialize.subscribe(async ({ cellId, sql }) => {
  const started = performance.now();
  const name = quoteIdent(cellId);
  try {
    // Cells are materialised rather than left as views: a cell in this model
    // *has a value*, and downstream cells reading a view would silently
    // re-execute their whole upstream chain on every query, which would make
    // the value cache meaningless. The cost is memory for intermediates,
    // which is acceptable at the file-sized scale this targets.
    await conn.query(`CREATE OR REPLACE TEMP TABLE ${name} AS (${sql})`);

    // The content hash is computed inside DuckDB so the value cache never
    // depends on pulling a whole result into JS. Aggregating with ORDER BY the
    // row text makes it deterministic under parallel execution, at the cost of
    // being order-*insensitive*: a cell whose only change is a reordering will
    // not invalidate its dependents. That is wrong for a query whose consumers
    // care about order (an ORDER BY feeding a LIMIT), and is a known gap to
    // close when the DSL can tell us whether a cell's order is significant.
    const stats = await conn.query(
      `SELECT count(*) AS n,
              md5(coalesce(string_agg(rt, chr(10) ORDER BY rt), '')) AS h
       FROM (SELECT CAST(t AS VARCHAR) AS rt FROM ${name} t)`
    );
    const { n, h } = plainRows(stats)[0];

    const preview = await conn.query(`SELECT * FROM ${name} LIMIT ${PREVIEW_ROWS}`);
    const rows = plainRows(preview);

    app.ports.queryOutcome.send({
      ok: true,
      cellId,
      columns: schemaOf(preview),
      rows,
      rowCount: Number(n),
      truncated: Number(n) > rows.length,
      hash: String(h),
      millis: performance.now() - started,
    });
  } catch (err) {
    app.ports.queryOutcome.send({
      ok: false,
      cellId,
      error: cleanError(err),
    });
  }
});

app.ports.dropTable.subscribe(async (cellId) => {
  if (!conn) return;
  try {
    await conn.query(`DROP TABLE IF EXISTS ${quoteIdent(cellId)}`);
  } catch {
    // A table that was never created is not an error worth reporting.
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
// generic table view and the typed decoder read the same rows.
function normalize(value) {
  if (value === null || value === undefined) return null;

  if (typeof value === 'bigint') {
    // DuckDB's default integer is BIGINT, so this is the common path, not an
    // edge case. Past 2^53 a Number would quietly lie, so those become strings
    // and a typed decoder expecting a number fails loudly instead.
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

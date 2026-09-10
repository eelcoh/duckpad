// Downloads the JavaScript duckpad loads at runtime into public/vendor/.
//
// A desktop app that needs the network to open a notebook is broken, and until
// this existed duckpad was one: duckdb-wasm was fetched from a CDN on first
// use. Vendoring also lets the packaged build run under a real CSP
// instead of none, since there is no longer a remote origin to allow.
//
// jsDelivr's `+esm` builds are not self-contained — they import further
// `/npm/...` paths — so this follows those imports, flattens each module to one
// file, and rewrites the specifiers to point at its neighbours. Data sources in
// notebooks stay remote: those are the reader's data, not duckpad's code.

const fs = require('fs');
const path = require('path');

const CDN = 'https://cdn.jsdelivr.net';
const DUCKDB = '@duckdb/duckdb-wasm@1.32.0';
// The engine embedded by that package. Extension paths are ABI-versioned, so
// update these two constants together.
const DUCKDB_ENGINE = 'v1.4.3';
const out = path.join(__dirname, '..', 'public', 'vendor');

// The two entry points, and the names the rest of the app imports them by.
const ENTRIES = {
  'duckdb.mjs': `/npm/${DUCKDB}/+esm`,
};

// DuckDB's worker and WebAssembly are fetched as whole files rather than
// modules: selectBundle normally hands back CDN URLs for these, and the bridge
// points it at these copies instead.
const ASSETS = [
  'duckdb-mvp.wasm',
  'duckdb-browser-mvp.worker.js',
  'duckdb-eh.wasm',
  'duckdb-browser-eh.worker.js',
];

const EXTENSION_ASSETS = [
  `${DUCKDB_ENGINE}/wasm_mvp/excel.duckdb_extension.wasm`,
  `${DUCKDB_ENGINE}/wasm_eh/excel.duckdb_extension.wasm`,
];

// A module path becomes one filename, so every rewritten import is a sibling.
const flatten = (spec) => spec.replace(/^\/npm\//, '').replace(/\/\+esm$/, '').replace(/[/@]/g, '_') + '.mjs';

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${url}`);
  return res.text();
}

// Whether everything this would download is already there.
//
// The guard lives here rather than in the mise task so it is one `node` call
// on every host: a shell `test -f` is not portable to a Windows CI runner, and
// the list of what counts as vendored belongs beside the list that produces it.
if (process.argv.includes('--check')) {
  const wanted = [
    ...Object.keys(ENTRIES),
    ...ASSETS,
    ...EXTENSION_ASSETS.map((asset) => path.join('extensions', asset)),
  ];
  process.exit(wanted.every((file) => fs.existsSync(path.join(out, file))) ? 0 : 1);
}

async function main() {
  fs.mkdirSync(out, { recursive: true });

  const named = new Map(Object.entries(ENTRIES).map(([file, spec]) => [spec, file]));
  const queue = [...named.keys()];
  const done = new Set();

  while (queue.length > 0) {
    const spec = queue.shift();
    if (done.has(spec)) continue;
    done.add(spec);

    let body = await fetchText(CDN + spec);

    // Every `/npm/...` this module imports becomes a sibling file, and is
    // itself queued.
    for (const dep of new Set(body.match(/\/npm\/[^"']+?\/\+esm/g) || [])) {
      if (!done.has(dep) && !queue.includes(dep)) queue.push(dep);
      body = body.split(`"${dep}"`).join(`"./${flatten(dep)}"`);
    }

    const file = named.get(spec) || flatten(spec);
    fs.writeFileSync(path.join(out, file), body);
    process.stdout.write(`  ${file} (${Math.round(body.length / 1024)}k)\n`);
  }

  for (const asset of ASSETS) {
    const res = await fetch(`${CDN}/npm/${DUCKDB}/dist/${asset}`);
    if (!res.ok) throw new Error(`${res.status} for ${asset}`);
    const bytes = Buffer.from(await res.arrayBuffer());
    fs.writeFileSync(path.join(out, asset), bytes);
    process.stdout.write(`  ${asset} (${Math.round(bytes.length / 1024)}k)\n`);
  }

  for (const asset of EXTENSION_ASSETS) {
    const res = await fetch(`https://extensions.duckdb.org/${asset}`);
    if (!res.ok) throw new Error(`${res.status} for ${asset}`);
    const bytes = Buffer.from(await res.arrayBuffer());
    const destination = path.join(out, 'extensions', asset);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, bytes);
    process.stdout.write(`  extensions/${asset} (${Math.round(bytes.length / 1024)}k)\n`);
  }

  console.log(`\nvendored ${done.size} modules, ${ASSETS.length} runtime assets and ${EXTENSION_ASSETS.length} extensions into public/vendor/`);
}

main().catch((err) => {
  console.error(`vendoring failed: ${err.message}`);
  process.exit(1);
});

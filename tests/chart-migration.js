// Guard the completed elm-charts migration at its non-Elm seams. A stale
// script tag or canvas repair would quietly keep shipping the retired Vega
// runtime even though Main no longer renders it.

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const checks = [
  ['Main renders ElmChart', read('src/Main.elm').includes('ElmChart.view')],
  ['the page has no Vega custom element', !read('public/index.html').includes('chart-element.js')],
  ['the Vega custom-element implementation is absent', !fs.existsSync(path.join(root, 'public/chart-element.js'))],
  ['static export needs no canvas snapshot', !read('public/export.js').includes('toDataURL')],
  ['the vendor manifest has no Vega entry', !read('tools/vendor.js').includes('vega-embed')],
  ['the retired Vega renderer is absent', !fs.existsSync(path.join(root, 'src/VegaChart.elm'))],
];

let failed = false;
for (const [name, ok] of checks) {
  console.log(`${ok ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  chart migration: ${name}`);
  failed ||= !ok;
}

process.exit(failed ? 1 : 0);

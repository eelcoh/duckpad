// Generated vendor files are ignored by Git, so removing their manifest entry
// does not remove copies left by an older checkout. Follow the old entry's
// relative imports and delete exactly that retired closure before packaging.

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..', 'public', 'vendor');
const retired = new Set();

function visit(file) {
  const absolute = path.join(root, file);
  if (retired.has(file) || !fs.existsSync(absolute)) return;
  retired.add(file);

  const source = fs.readFileSync(absolute, 'utf8');
  for (const match of source.matchAll(/(?:from\s*|import\s*)["'`](?:\.\/)([^"'`]+\.mjs)["'`]/g)) {
    visit(match[1]);
  }
}

visit('vega-embed.mjs');
for (const file of retired) fs.unlinkSync(path.join(root, file));

if (retired.size > 0) {
  console.log(`removed ${retired.size} retired Vega vendor files`);
}

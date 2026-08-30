// Writes the seeded notebook to public/notebooks/ so it can be opened as a
// file, and so the repository carries a worked example of the file format.
const fs = require('fs');
const path = require('path');
const { Elm } = require('./seed.js');

const OUT = path.resolve(__dirname, '..', 'public', 'notebooks', 'flights.note-ml.md');

Elm.EmitSeed.init().ports.emit.subscribe(({ markdown, roundTripped }) => {
  if (markdown !== roundTripped) {
    console.error('the seeded notebook does not survive a parse and re-serialise');
    process.exit(1);
  }
  fs.writeFileSync(OUT, markdown);
  console.log(`wrote ${path.relative(process.cwd(), OUT)} (${markdown.length} bytes, round-trips)`);
});

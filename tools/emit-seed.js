// Writes the seeded notebook to public/notebooks/ so it can be opened as a
// file, and so the repository carries a worked example of the file format.
const fs = require('fs');
const path = require('path');
const { Elm } = require('./seed.js');

const DIR = path.resolve(__dirname, '..', 'public', 'notebooks');

Elm.EmitSeed.init().ports.emit.subscribe((notebooks) => {
  for (const { name, markdown, roundTripped } of notebooks) {
    if (markdown !== roundTripped) {
      console.error(`${name} does not survive a parse and re-serialise`);
      process.exit(1);
    }
    const out = path.join(DIR, name);
    fs.writeFileSync(out, markdown);
    console.log(`wrote ${path.relative(process.cwd(), out)} (${markdown.length} bytes, round-trips)`);
  }
});

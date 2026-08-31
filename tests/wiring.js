// Checks that every port Elm declares is actually connected on the JavaScript
// side.
//
// The bridge is the one part of duckpad with no Elm types holding it together,
// and a missing handler fails silently: the notebook loads, the buttons render,
// and the thing behind them never happens. That is how the whole of boot()
// once went missing without a single check going red. Ports are read from
// Ports.elm rather than listed here so this cannot drift from the real ones.

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const RED = '\x1b[31m';
const GREEN = '\x1b[32m';
const RESET = '\x1b[0m';

const ports = fs
  .readFileSync(path.join(root, 'src/Ports.elm'), 'utf8')
  .split('\n')
  .flatMap((line) => {
    const m = line.match(/^port (\w+) :(.*)$/);
    if (!m) return [];
    // An incoming port takes a message constructor and yields a Sub; an
    // outgoing one takes a value and yields a Cmd.
    return [{ name: m[1], direction: m[2].includes('Sub msg') ? 'send' : 'subscribe' }];
  });

const js = fs
  .readdirSync(path.join(root, 'public'))
  .filter((f) => f.endsWith('.js') && f !== 'elm.js')
  .map((f) => fs.readFileSync(path.join(root, 'public', f), 'utf8'))
  .join('\n');

const failures = [];
for (const { name, direction } of ports) {
  if (!js.includes(`ports.${name}.${direction}`)) {
    failures.push(`${name} is never ${direction === 'send' ? 'sent to' : 'subscribed to'}`);
  }
}

if (ports.length === 0) failures.push('no ports found in src/Ports.elm — the parser is wrong');

for (const f of failures) console.log(`${RED}FAIL${RESET}  ${f}`);
if (failures.length === 0) {
  console.log(`${GREEN}PASS${RESET}  all ${ports.length} ports are wired up in public/`);
}
process.exit(failures.length === 0 ? 0 : 1);

// Runs the Elm test worker under Node and reports the result.
//
// Elm's compiled output assigns to `this`, which is `module.exports` under
// CommonJS, so the worker can simply be required.
const { Elm } = require('./tests.js');

const GREEN = '[32m';
const RED = '[31m';
const RESET = '[0m';

const app = Elm.TestRunner.init();

app.ports.report.subscribe((checks) => {
  const failed = checks.filter((c) => !c.ok);

  for (const c of checks) {
    const mark = c.ok ? GREEN + 'PASS' + RESET : RED + 'FAIL' + RESET;
    console.log(mark + '  ' + c.name);
    if (c.detail) console.log('      ' + c.detail);
  }

  console.log(
    '\n' + (checks.length - failed.length) + '/' + checks.length + ' checks passed'
  );
  process.exit(failed.length === 0 ? 0 : 1);
});

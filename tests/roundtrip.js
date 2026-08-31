// Round-trip validation for the DSL compiler.
//
// The Elm test suite can check that codegen produces the *text* we expect.
// It cannot check that the text is valid SQL or valid Elm. This harness does
// exactly that, and nothing else: every fixture's SQL is executed against a
// real DuckDB built from the sample CSV, and every generated module is put
// through `elm make`.

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const { Elm } = require('./fixtures.js');

const REPO = path.resolve(__dirname, '..');
const WORK = path.join(REPO, 'tests', '.roundtrip');
const CSV = path.join(REPO, 'public', 'data', 'orders.csv');
const CUSTOMERS = path.join(REPO, 'public', 'data', 'customers.csv');

// The tables the fixture schema claims exist. Kept here rather than in a
// checked-in .sql file so the schema and its DuckDB counterpart stay adjacent.
const SETUP = `
CREATE TABLE orders AS SELECT * FROM read_csv_auto('${CSV}');
CREATE TABLE vips AS SELECT DISTINCT owner FROM orders ORDER BY owner LIMIT 3;
CREATE TABLE regions AS SELECT DISTINCT region FROM orders;
CREATE TABLE customers AS SELECT * FROM read_csv_auto('${CUSTOMERS}');
CREATE TABLE people AS SELECT DISTINCT owner AS person, length(owner) AS rank FROM orders;

-- A cell the tutorial's chart reads, so its query can be checked like the rest.
CREATE TABLE by_region AS
  SELECT region, count(*) AS orders, round(sum(total), 2) AS revenue FROM orders GROUP BY region;

-- Wide on purpose: the shape unpivot exists for, which nothing else here has.
CREATE TABLE quarterly AS
  SELECT region,
         round(sum(total) * 0.20, 2) AS q1,
         round(sum(total) * 0.30, 2) AS q2,
         round(sum(total) * 0.25, 2) AS q3,
         round(sum(total) * 0.25, 2) AS q4
  FROM orders GROUP BY region;

-- Stand-ins for the two remote sources the seeded notebook ships with. The
-- schemas match what DuckDB infers from the real files, so the seeded cells
-- are checked for real without the tests needing a network.
CREATE TABLE airports (
  iata VARCHAR, name VARCHAR, city VARCHAR, state VARCHAR,
  country VARCHAR, latitude DOUBLE, longitude DOUBLE
);
INSERT INTO airports VALUES
  ('SFO','San Francisco Intl','San Francisco','CA','USA',37.6,-122.4),
  ('LAX','Los Angeles Intl','Los Angeles','CA','USA',33.9,-118.4),
  ('ORD','Chicago OHare Intl','Chicago','IL','USA',42.0,-87.9),
  ('ROR','Babelthuap','Babelthuap','ROR','Palau',7.4,134.5);

CREATE TABLE flights (
  date TIMESTAMP, delay BIGINT, distance BIGINT, origin VARCHAR, destination VARCHAR
);
INSERT INTO flights VALUES
  (TIMESTAMP '2001-01-01 10:00:00', 12, 337, 'SFO', 'LAX'),
  (TIMESTAMP '2001-01-01 11:00:00', -4, 337, 'LAX', 'SFO'),
  (TIMESTAMP '2001-01-02 09:00:00', 33, 1745, 'ORD', 'LAX');
`;

const ELM_JSON = {
  type: 'application',
  'source-directories': ['src'],
  'elm-version': '0.19.2',
  dependencies: {
    direct: {
      'elm/core': '1.0.5',
      'elm/json': '1.1.4',
      'elm/time': '1.0.0',
    },
    indirect: {},
  },
  'test-dependencies': { direct: {}, indirect: {} },
};

const app = Elm.Fixtures.init();

app.ports.emit.subscribe((fixtures) => {
  fs.rmSync(WORK, { recursive: true, force: true });
  fs.mkdirSync(path.join(WORK, 'src'), { recursive: true });
  fs.writeFileSync(
    path.join(WORK, 'elm.json'),
    JSON.stringify(ELM_JSON, null, 4)
  );

  const results = [];

  for (const fixture of fixtures) {
    if (!fixture.ok) {
      results.push({ name: fixture.name, stage: 'compile', error: fixture.error });
      continue;
    }
    results.push(...checkSql(fixture));
    results.push(...checkElm(fixture));
  }

  report(results, fixtures.length);
});

function checkSql(fixture) {
  try {
    // Wrapped in a view so DuckDB parses and binds the whole statement,
    // including the ORDER BY and LIMIT, before anything is executed.
    run('duckdb', [
      '-c',
      `${SETUP}\nCREATE VIEW check_${fixture.module} AS ${fixture.sql};\nSELECT count(*) FROM check_${fixture.module};`,
    ]);
    return [];
  } catch (err) {
    return [
      {
        name: fixture.name,
        stage: 'sql',
        error: err.stderr || err.message,
        detail: fixture.sql,
      },
    ];
  }
}

function checkElm(fixture) {
  const file = path.join(WORK, 'src', `${fixture.module}.elm`);
  fs.writeFileSync(file, fixture.elm);
  try {
    run('elm', ['make', path.join('src', `${fixture.module}.elm`), '--output=/dev/null'], WORK);
    return [];
  } catch (err) {
    return [
      {
        name: fixture.name,
        stage: 'elm',
        error: err.stdout || err.stderr || err.message,
        detail: fixture.elm,
      },
    ];
  }
}

function run(tool, args, cwd) {
  return execFileSync('mise', ['exec', '--', tool, ...args], {
    cwd: cwd || REPO,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function report(failures, total) {
  const GREEN = '[32m';
  const RED = '[31m';
  const RESET = '[0m';

  if (failures.length === 0) {
    console.log(
      `${GREEN}PASS${RESET}  ${total} fixtures: SQL executed against DuckDB, modules compiled by elm make`
    );
    process.exit(0);
  }

  for (const f of failures) {
    console.log(`${RED}FAIL${RESET}  ${f.name} (${f.stage})`);
    console.log(indent(f.error.trim(), 6));
    if (f.detail) {
      console.log(indent('--- generated ---', 6));
      console.log(indent(f.detail.trim(), 6));
    }
  }
  console.log(`\n${failures.length} failure(s) across ${total} fixtures`);
  process.exit(1);
}

function indent(text, spaces) {
  const pad = ' '.repeat(spaces);
  return text
    .split('\n')
    .map((l) => pad + l)
    .join('\n');
}

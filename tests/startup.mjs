import assert from 'node:assert/strict';
import { chooseStartup } from '../public/startup.mjs';

const disk = { content: 'disk', modified: 200 };

// `now` is a clock reading, so it is checked for shape and then dropped: the
// rest of the decision is what the tests are about.
function chose(recovered, restored, recents, formerPath) {
  const flags = chooseStartup(recovered, restored, recents, formerPath);
  assert.equal(typeof flags.now, 'number');
  const { now, ...rest } = flags;
  return rest;
}

const associated = { associated: true, home: false, formerPath: null, recents: [] };
const alone = { associated: false, home: true, formerPath: null, recents: [] };

assert.deepEqual(chose(null, disk), { saved: 'disk', dirty: false, ...associated });
assert.deepEqual(chose({ content: 'edit', modified: 300 }, disk), {
  saved: 'edit', dirty: true, ...associated,
});
assert.deepEqual(chose({ content: 'stale', modified: 100 }, disk), {
  saved: 'disk', dirty: false, ...associated,
});
assert.deepEqual(chose({ content: 'draft', modified: 300 }, null), {
  saved: 'draft', dirty: false, ...alone,
});
assert.deepEqual(chose({ content: 'disk', modified: 300 }, disk), {
  saved: 'disk', dirty: false, ...associated,
});

// The home screen is exactly the unassociated case. A restored association is
// the only state with a known base directory, so it is the only one allowed to
// open straight into a document and start running cells.
assert.equal(chose(null, disk).home, false, 'an associated document skips home');
assert.equal(chose(null, null).home, true, 'a cold start goes to home');
assert.equal(chose({ content: 'draft', modified: 1 }, null).home, true,
  'a recovery copy with no file goes to home');
assert.equal(chose(null, null).saved, null, 'a cold start recovers nothing');

// A moved file leaves its former path behind as a hint for Locate, and never
// as an association: the content is still unmoored from any directory.
const moved = chose({ content: 'draft', modified: 1 }, null, [], '/gone/n.duckpad.md');
assert.equal(moved.formerPath, '/gone/n.duckpad.md');
assert.equal(moved.associated, false, 'a former path is a hint, not an association');
assert.equal(moved.home, true, 'a moved file still lands on home');

// The index is passed through untouched, and its absence is an empty list
// rather than something Elm has to decode as missing.
const entries = [{ key: '/a.duckpad.md', name: 'a.duckpad.md', opened: 5, unsaved: true, reachable: true }];
assert.deepEqual(chose(null, null, entries).recents, entries);
assert.deepEqual(chose(null, null, undefined).recents, []);

console.log('\x1b[32mPASS\x1b[0m  startup chooses disk, recovery and association safely');
console.log('\x1b[32mPASS\x1b[0m  home is chosen exactly when no document location is known');

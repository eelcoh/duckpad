import assert from 'node:assert/strict';
import { chooseStartup } from '../public/startup.mjs';

const disk = { content: 'disk', modified: 200 };

assert.deepEqual(chooseStartup(null, disk), {
  saved: 'disk', associated: true, dirty: false,
});
assert.deepEqual(chooseStartup({ content: 'edit', modified: 300 }, disk), {
  saved: 'edit', associated: true, dirty: true,
});
assert.deepEqual(chooseStartup({ content: 'stale', modified: 100 }, disk), {
  saved: 'disk', associated: true, dirty: false,
});
assert.deepEqual(chooseStartup({ content: 'draft', modified: 300 }, null), {
  saved: 'draft', associated: false, dirty: false,
});
assert.deepEqual(chooseStartup({ content: 'disk', modified: 300 }, disk), {
  saved: 'disk', associated: true, dirty: false,
});

console.log('\x1b[32mPASS\x1b[0m  startup chooses disk, recovery and association safely');

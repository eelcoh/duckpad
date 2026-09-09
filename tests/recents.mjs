import assert from 'node:assert/strict';

// The index is browser state, so the browser's shape has to exist before the
// module is imported. No file picker is offered, which is what keeps the
// handle store out of the way: it has nothing to hold.
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
};
globalThis.window = {};

const recents = await import('../public/recents.mjs');

assert.deepEqual(recents.listRecents(), [], 'an empty index reads as no entries');

recents.rememberRecent({ key: '/a.duckpad.md', name: 'a.duckpad.md', path: '/a.duckpad.md' });
recents.rememberRecent({ key: '/b.duckpad.md', name: 'b.duckpad.md', path: '/b.duckpad.md' });

assert.deepEqual(recents.listRecents().map((e) => e.key), ['/b.duckpad.md', '/a.duckpad.md'],
  'the most recently opened comes first');

// Re-opening something already listed moves it, rather than listing it twice.
recents.rememberRecent({ key: '/a.duckpad.md', name: 'a.duckpad.md', path: '/a.duckpad.md' });
assert.deepEqual(recents.listRecents().map((e) => e.key), ['/a.duckpad.md', '/b.duckpad.md'],
  're-opening an entry moves it to the front rather than duplicating it');
assert.equal(recents.listRecents().length, 2);

// The load-bearing invariant: this is a pointer list. If a notebook's text
// could reach it, the index would become a second copy that nothing keeps in
// step with the file, and clearing it would lose work.
recents.rememberRecent({
  key: '/c.duckpad.md', name: 'c.duckpad.md', path: '/c.duckpad.md',
  content: '# secret', markdown: '# secret', handle: null,
});
const serialised = store.get('duckpad.recents');
assert.ok(!serialised.includes('secret'), 'the index never stores notebook contents');
assert.deepEqual(Object.keys(recents.listRecents()[0]).sort(),
  ['key', 'name', 'opened', 'path', 'reachable', 'unsaved'],
  'an entry carries only pointer fields');

recents.markUnsaved('/c.duckpad.md', true);
assert.equal(recents.listRecents()[0].unsaved, true, 'unsaved edits are recorded against the entry');
recents.markUnsaved('/missing.duckpad.md', true);
assert.equal(recents.listRecents().length, 3, 'marking an unknown entry adds nothing');

recents.forgetRecent('/c.duckpad.md');
assert.deepEqual(recents.listRecents().map((e) => e.key), ['/a.duckpad.md', '/b.duckpad.md'],
  'forgetting removes exactly one entry');

// The index is convenience: storage that throws must not take the app down.
globalThis.localStorage.setItem = () => { throw new Error('quota'); };
recents.rememberRecent({ key: '/d.duckpad.md', name: 'd.duckpad.md', path: '/d.duckpad.md' });
globalThis.localStorage.getItem = () => { throw new Error('blocked'); };
assert.deepEqual(recents.listRecents(), [], 'unreadable storage reads as an empty index');

console.log('\x1b[32mPASS\x1b[0m  recents index points at documents and never copies them');

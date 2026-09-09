// The home screen must not execute anything.
//
// This is the whole point of the screen. Restoring a buffer without knowing
// which directory it came from used to run every relative data path against
// whatever directory the process started in, so the reader was met with a
// page of load failures that looked like a corrupt notebook. A document with
// no known location must therefore reach `schedule` and be turned away.
//
// The check runs the real compiled program against a DOM stub, because the
// guard lives in Elm's update loop and nothing smaller would exercise it. The
// second case is the control: without it a bug that stopped all execution
// would pass as a success.

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');

function element(tag) {
  return {
    tagName: String(tag || '').toUpperCase(), nodeType: 1, childNodes: [], style: {},

    // Elm virtualizes the mount point on init, which walks both of these.
    attributes: [],
    classList: { add() {}, remove() {}, contains: () => false },
    appendChild(c) { this.childNodes.push(c); c.parentNode = this; return c; },
    insertBefore(c) { this.childNodes.push(c); c.parentNode = this; return c; },
    removeChild(c) { this.childNodes = this.childNodes.filter((x) => x !== c); return c; },
    replaceChild(next, old) {
      const at = this.childNodes.indexOf(old);
      if (at >= 0) this.childNodes[at] = next; else this.childNodes.push(next);
      next.parentNode = this;
      return old;
    },
    setAttribute() {}, setAttributeNS() {}, removeAttribute() {}, removeAttributeNS() {},
    addEventListener() {}, removeEventListener() {}, focus() {}, contains: () => false,
    replaceData() {},
    get firstChild() { return this.childNodes[0] || null; },
    get parentNode() { return this._parent || null; },
    set parentNode(v) { this._parent = v; },
    get textContent() { return this.childNodes.map((c) => c.textContent || '').join(''); },
    set textContent(_) {},
  };
}

function textNode(data) {
  return {
    nodeType: 3, data, textContent: data, replaceData() {},
    get parentNode() { return this._parent || null; },
    set parentNode(v) { this._parent = v; },
  };
}

globalThis.document = {
  body: element('body'), documentElement: element('html'), title: '',
  createElement: element, createElementNS: (_, tag) => element(tag), createTextNode: textNode,
  addEventListener() {}, removeEventListener() {}, getElementById: () => null,
};
globalThis.document.body.parentNode = globalThis.document.documentElement;
globalThis.window = globalThis;
globalThis.navigator = { userAgent: 'node', language: 'en-GB' };
globalThis.location = { href: 'http://localhost/', protocol: 'http:', host: 'localhost' };
globalThis.history = { state: null, pushState() {}, replaceState() {} };
globalThis.requestAnimationFrame = (f) => setTimeout(() => f(Date.now()), 0);
globalThis.cancelAnimationFrame = clearTimeout;

const { Elm } = require(path.join(root, 'public', 'elm.js'));
const notebook = fs.readFileSync(path.join(root, 'public', 'tutorial.duckpad.md'), 'utf8');

const base = {
  saved: notebook, associated: false, dirty: false,
  formerPath: null, recents: [], now: Date.now(),
};

function start(flags) {
  return new Promise((resolve) => {
    const mount = element('div');
    globalThis.document.body.appendChild(mount);
    const app = Elm.Main.init({ node: mount, flags });
    const fired = [];
    app.ports.loadSource.subscribe((s) => fired.push('loadSource:' + s.cellId));
    app.ports.materialize.subscribe((m) => fired.push('materialize:' + m.cellId));

    // The bridge reports a booted database exactly this way; anything else
    // leaves the model unready and would make both cases trivially quiet.
    app.ports.dbReady.send({ ok: true, schema: [] });
    setTimeout(() => resolve({ app, fired, mount }), 200);
  });
}

function fail(message) {
  console.error('\x1b[31mFAIL\x1b[0m  ' + message);
  process.exit(1);
}

(async () => {
  const home = await start({ ...base, home: true });
  if (home.fired.length !== 0) {
    fail('the home screen ran ' + home.fired.length + ' cells: ' + home.fired.join(', '));
  }

  const document_ = await start({ ...base, home: false, associated: true });
  if (document_.fired.length === 0) {
    fail('an associated document ran nothing, so the home check proves nothing');
  }

  const rendered = home.mount.textContent;
  // Both seeded notebooks have to be reachable from here. They are the only
  // way in for a reader with no file of their own, and the tutorial is the
  // one that needs no network.
  for (const wanted of ['New notebook', 'Open…', 'Open the tutorial', 'Open the example']) {
    if (!rendered.includes(wanted)) fail('the home screen is missing "' + wanted + '"');
  }

  // The recovery card has to tell a moved file apart from work that never
  // had one. Both branches are checked because the first was unreachable for
  // a while: every link from Rust to the view existed except the one that
  // supplied the path, so the card silently always claimed the second.
  const moved = await start({ ...base, home: true, dirty: true, formerPath: '/notes/gone.duckpad.md' });
  if (!moved.mount.textContent.includes('no longer at /notes/gone.duckpad.md')) {
    fail('a recovered copy whose file moved does not name where it was');
  }

  const orphan = await start({ ...base, home: true, dirty: true });
  if (!orphan.mount.textContent.includes('never saved to a file')) {
    fail('a recovered copy with no file does not say so');
  }
  if (orphan.mount.textContent.includes('no longer at')) {
    fail('a recovered copy with no file claims one moved');
  }

  console.log('\x1b[32mPASS\x1b[0m  the home screen runs no cells, and a located document still does');
  console.log('\x1b[32mPASS\x1b[0m  a recovered copy says whether its file moved or never existed');
})();

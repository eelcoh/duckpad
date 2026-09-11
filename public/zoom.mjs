// Text size, owned by the page rather than by the webview.
//
// Tauri has zoom hotkeys of its own, but they are off by default and, were
// they on, the page could not read the level back — the webview keeps it to
// itself. Owning the factor is what makes it persistable, and persistence is
// the part that matters: someone who needs larger text needs it on every
// launch, not once per session.
//
// Scaling the whole page rather than restyling it is deliberate. elm-ui writes
// its font sizes as inline pixels, so a CSS root size would leave most of the
// interface untouched; zoom reaches all of it, including the result tables and
// the editor, and keeps every proportion the design already settled.

const KEY = 'duckpad.zoom';

// Coarse enough that a keypress is always visible, and bounded because a
// notebook laid out below about 0.8 starts truncating its own toolbars.
export const STEPS = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5];
export const DEFAULT = 1;

let current = DEFAULT;

export function nearestStep(factor) {
  return STEPS.reduce((best, step) =>
    Math.abs(step - factor) < Math.abs(best - factor) ? step : best
  , STEPS[0]);
}

function read() {
  try {
    const stored = Number(localStorage.getItem(KEY));
    return Number.isFinite(stored) && stored > 0 ? nearestStep(stored) : DEFAULT;
  } catch {
    // Storage disabled. The zoom still works, it just will not be remembered.
    return DEFAULT;
  }
}

function save(factor) {
  try {
    localStorage.setItem(KEY, String(factor));
  } catch {
    // As above: losing the preference is not worth failing the keystroke over.
  }
}

async function apply(factor) {
  current = factor;
  const tauri = window.__TAURI__;
  if (tauri && tauri.webviewWindow) {
    try {
      await tauri.webviewWindow.getCurrentWebviewWindow().setZoom(factor);
      return;
    } catch {
      // Falls through to the CSS route, which is also what the browser build
      // uses, so a missing capability degrades rather than breaks.
    }
  }
  document.documentElement.style.zoom = String(factor);
}

/*
 * Pure so it can be tested without a window: the clamping at both ends is the
 * part with an off-by-one in it, not the keystroke that calls it.
 */
export function stepFrom(factor, direction) {
  const at = STEPS.indexOf(nearestStep(factor));
  return STEPS[Math.min(STEPS.length - 1, Math.max(0, at + direction))];
}

function step(direction) {
  const next = stepFrom(current, direction);
  if (next !== current) {
    apply(next);
    save(next);
  }
}

function reset() {
  apply(DEFAULT);
  save(DEFAULT);
}

/*
 * Cmd on macOS, Ctrl elsewhere. `+` is reported as `=` unshifted and `+`
 * shifted, and some layouts send the numpad names instead, so all of them
 * are accepted rather than guessing at the reader's keyboard.
 */
function onKeyDown(event) {
  if (!(event.metaKey || event.ctrlKey) || event.altKey) return;

  if (event.key === '=' || event.key === '+' || event.key === 'Add') {
    event.preventDefault();
    step(1);
  } else if (event.key === '-' || event.key === '_' || event.key === 'Subtract') {
    event.preventDefault();
    step(-1);
  } else if (event.key === '0') {
    event.preventDefault();
    reset();
  }
}

export function install() {
  apply(read());
  window.addEventListener('keydown', onKeyDown);
}

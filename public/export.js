// Saving a notebook as a self-contained page.
//
// Not the same thing as the .md file, which is the document: this is the
// notebook *as it currently stands*, results and all, for handing to someone
// who wants to read what you found rather than re-run it. It carries no
// database, fetches nothing, and does not need this application to open.
//
// It works by snapshotting the rendered page rather than re-deriving it,
// which is the only way to be sure the export shows what the reader was
// looking at. Elm charts are SVG and survive DOM cloning as-is. Two things do
// need repair: editors are textareas whose contents are a property rather than
// markup, and every control is inert once the scripts are gone and so should
// not be there at all.

import { saveExport } from './files.js';

export function exportStatic(name) {
  // The DOM has to have caught up with whatever Elm changed on the way here.
  requestAnimationFrame(() => {
    try {
      saveExport(name, buildPage());
    } catch (err) {
      console.error('[duckpad] export failed', err);
    }
  });
}

function buildPage() {
  const clone = document.documentElement.cloneNode(true);

  freezeEditors(clone);
  removeControls(clone);
  removeScripts(clone);

  return '<!doctype html>\n' + clone.outerHTML;
}

// A textarea's value is a property, so the clone would serialise as empty. For
// a code cell the coloured layer underneath already shows the source, so the
// textarea goes; prose being edited would otherwise vanish, so it becomes text.
function freezeEditors(clone) {
  const live = [...document.querySelectorAll('.cell-source')];
  [...clone.querySelectorAll('.cell-source')].forEach((editor, i) => {
    const value = live[i] ? live[i].value : '';
    const inEditor = editor.parentElement && editor.parentElement.classList.contains('editor');
    if (inEditor) {
      editor.remove();
      return;
    }
    const rendered = document.createElement('div');
    rendered.className = 'prose-body';
    rendered.textContent = value;
    editor.replaceWith(rendered);
  });
}

// Text inputs keep their value the same way, and are replaced by what they say
// rather than left as fields nothing is listening to.
function removeControls(clone) {
  const liveInputs = [...document.querySelectorAll('input[type=text], input:not([type])')];
  [...clone.querySelectorAll('input[type=text], input:not([type])')].forEach((field, i) => {
    const span = document.createElement('span');
    span.textContent = liveInputs[i] ? liveInputs[i].value : '';
    span.setAttribute('style', field.getAttribute('style') || '');
    span.className = field.className;
    field.replaceWith(span);
  });

  clone.querySelectorAll('[data-export="drop"]').forEach((el) => el.remove());
  clone.querySelectorAll('button').forEach((el) => el.remove());
}

function removeScripts(clone) {
  clone.querySelectorAll('script').forEach((el) => el.remove());
}

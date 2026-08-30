// Saving a notebook as a self-contained page.
//
// Not the same thing as the .md file, which is the document: this is the
// notebook *as it currently stands*, results and all, for handing to someone
// who wants to read what you found rather than re-run it. It carries no
// database, fetches nothing, and does not need this application to open.
//
// It works by snapshotting the rendered page rather than re-deriving it,
// which is the only way to be sure the export shows what the reader was
// looking at. Three things have to be repaired in the copy: charts live in a
// canvas that does not survive serialisation, editors are textareas whose
// contents are a property rather than markup, and every control is inert once
// the scripts are gone and so should not be there at all.

export function exportStatic(name) {
  // The DOM has to have caught up with whatever Elm changed on the way here.
  requestAnimationFrame(() => {
    try {
      download(name, buildPage());
    } catch (err) {
      console.error('[acadia] export failed', err);
    }
  });
}

function buildPage() {
  const charts = snapshotCharts();
  const clone = document.documentElement.cloneNode(true);

  restoreCharts(clone, charts);
  freezeEditors(clone);
  removeControls(clone);
  removeScripts(clone);

  return '<!doctype html>\n' + clone.outerHTML;
}

// Canvases are read from the live page, because a cloned canvas is blank: its
// pixels are not part of the markup.
function snapshotCharts() {
  return [...document.querySelectorAll('vega-chart')].map((chart) => {
    const canvas = chart.querySelector('canvas');
    return canvas
      ? { url: canvas.toDataURL('image/png'), width: canvas.clientWidth, height: canvas.clientHeight }
      : null;
  });
}

function restoreCharts(clone, charts) {
  [...clone.querySelectorAll('vega-chart')].forEach((chart, i) => {
    const shot = charts[i];
    chart.replaceChildren();
    if (!shot) {
      chart.textContent = 'chart not drawn';
      return;
    }
    const img = document.createElement('img');
    img.src = shot.url;
    img.width = shot.width;
    img.height = shot.height;
    img.style.maxWidth = '100%';
    chart.appendChild(img);
  });
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

function download(name, html) {
  const url = URL.createObjectURL(new Blob([html], { type: 'text/html' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}

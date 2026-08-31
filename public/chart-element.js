// A custom element for Vega-Lite charts.
//
// A custom element rather than a port because the lifecycle is the hard part:
// a port would have to find a div that may not exist yet, and clean up after
// one that has gone. Elm creates and removes this node like any other, and
// setting the `spec` property is what redraws it.
//
// Vega is imported the first time a chart appears. It is over a megabyte, and
// a notebook of tables should not pay for it.

let vega = null;

function loadVega() {
  if (!vega) {
    vega = import('./vendor/vega-embed.mjs');
  }
  return vega;
}

class VegaChart extends HTMLElement {
  set spec(value) {
    this._spec = value;
    this.render();
  }

  connectedCallback() {
    this.render();
  }

  disconnectedCallback() {
    this.teardown();
  }

  teardown() {
    if (this._view) {
      this._view.finalize();
      this._view = null;
    }
  }

  async render() {
    if (!this.isConnected || !this._spec) return;

    // Each render supersedes any still in flight: the spec can change while
    // Vega is being fetched, and the last one asked for is the one to draw.
    const token = {};
    this._token = token;

    try {
      const { default: embed } = await loadVega();
      if (this._token !== token || !this.isConnected) return;

      this.teardown();
      const result = await embed(this, this._spec, {
        actions: false,
        renderer: 'canvas',
      });
      if (this._token !== token) {
        result.finalize();
        return;
      }
      this._view = result.view;
    } catch (err) {
      this.textContent = `chart could not be drawn: ${err}`;
    }
  }
}

customElements.define('vega-chart', VegaChart);

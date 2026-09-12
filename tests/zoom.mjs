import assert from 'node:assert/strict';

// zoom.mjs touches the DOM only from `install`, so importing it needs no
// browser — which is the point of keeping the stepping pure.
const zoom = await import('../public/zoom.mjs');

const { STEPS, DEFAULT, nearestStep, stepFrom } = zoom;

assert.ok(STEPS.includes(DEFAULT), 'the default is one of the steps, so resetting lands on the ladder');
assert.deepEqual([...STEPS].sort((a, b) => a - b), STEPS, 'the steps ascend');

// Stepping.
assert.equal(stepFrom(1, 1), 1.1, 'stepping up from 100% goes to the next rung');
assert.equal(stepFrom(1, -1), 0.9, 'stepping down from 100% goes to the previous rung');
assert.equal(stepFrom(1.25, 1), 1.5, 'the rungs widen as they climb');

// The ends are where an off-by-one would live.
assert.equal(stepFrom(2.5, 1), 2.5, 'the largest step will not go past itself');
assert.equal(stepFrom(0.8, -1), 0.8, 'the smallest step will not go past itself');

// A stored value from an older ladder, or a webview that rounded it, still has
// to land somewhere sensible rather than resetting to 100%.
assert.equal(nearestStep(1.23), 1.25, 'an off-ladder factor snaps to the closest rung');
assert.equal(nearestStep(0.1), 0.8, 'a factor below the ladder snaps to the smallest');
assert.equal(nearestStep(9), 2.5, 'a factor above the ladder snaps to the largest');
assert.equal(stepFrom(1.23, 1), 1.5, 'stepping from an off-ladder factor moves off the rung it snapped to');

console.log('[32mPASS[0m  zoom steps stay on the ladder and stop at both ends');

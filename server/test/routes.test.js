import test from 'node:test';
import assert from 'node:assert/strict';
import { meters, score, selectRoutes, parseTarget } from '../routes.js';
const target = { lat: 0, lon: 0, radius: 5000, distance: 8000, ascent: 100 };
const route = { id: 'a', distance: 8000, ascent: 100, coordinates: [[0, 0], [.01, .01], [0, 0]] };
test('distance calculation respects geographic units', () => assert.ok(Math.abs(meters([0, 0], [0, 1]) - 111195) < 2));
test('exact effort target ranks above mismatches', () => { assert.equal(score(route, 8000, 100), 1); assert.ok(score({ ...route, distance: 9000 }, 8000, 100) < 1); });
test('rejects routes outside home radius and non-loops', () => {
  assert.equal(selectRoutes([{ ...route, coordinates: [[0, 0], [1, 1], [0, 0]] }], target).length, 0);
  assert.equal(selectRoutes([{ ...route, coordinates: [[0, 0], [.01, .01]] }], target).length, 0);
});
test('deduplicates alternatives and filters effort mismatch', () => {
  assert.equal(selectRoutes([route, { ...route, id: 'b' }, { ...route, distance: 14000 }], target).length, 1);
  assert.equal(selectRoutes([{ ...route, ascent: 500 }], target).length, 0);
});
test('requires finite parameters and accepts zero elevation', () => {
  assert.throws(() => parseTarget(new URLSearchParams('lat=0')));
  const query = new URLSearchParams({ ...target, ascent: 0 });
  assert.equal(parseTarget(query).ascent, 0);
  query.set('radius', 'Infinity'); assert.throws(() => parseTarget(query));
});

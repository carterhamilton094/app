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

test('no-match explanations distinguish radius, distance, climbing and retraced routes', async () => {
  const { noMatchMessage } = await import('../routes.js');
  const outside = { ...route, coordinates: [[0, 0], [1, 1], [0, 0]] };
  assert.match(noMatchMessage([outside], target), /left your 5.0 km home radius/);
  assert.match(noMatchMessage([{ ...route, distance: 4000 }], target), /4.0–4.0 km.*target is 8.0 km/);
  assert.match(noMatchMessage([{ ...route, ascent: 250 }], target), /climbed 250–250 m.*target is 100 m/);
  assert.match(noMatchMessage([route], target, route.coordinates), /retraced your recorded run/);
  assert.match(noMatchMessage([], target), /No walkable loop/);
});
test('every filter is reported when a candidate fails multiple matching rules', async () => {
  const { routeRejections } = await import('../routes.js');
  const bad = { ...route, distance: 20000, ascent: 500, coordinates: [[0, 0], [1, 1], [1, 1]] };
  assert.deepEqual(routeRejections(bad, target), ['radius', 'closure', 'distance', 'climb']);
});

test('closest options may differ in climbing but still require distance, radius and loop closure', () => {
  const hilly = { ...route, ascent: 500 };
  const outside = { ...hilly, coordinates: [[0, 0], [1, 1], [0, 0]] };
  const long = { ...hilly, distance: 16000 };
  const open = { ...hilly, coordinates: [[0, 0], [.01, .01], [.02, .02]] };
  assert.equal(selectRoutes([hilly], target).length, 0);
  const closest = selectRoutes([hilly, outside, long, open], target, { allowClimbDifference: true });
  assert.equal(closest.length, 1);
  assert.equal(closest[0].ascent, 500);
});

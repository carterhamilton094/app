import test from 'node:test';
import assert from 'node:assert/strict';
import { decodePolyline, runningActivities, targetForRun } from '../activities.js';
import { retraces } from '../routes.js';

test('Strava polyline becomes longitude/latitude coordinates for native maps', () => {
  assert.deepEqual(decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@'), [
    [-120.2, 38.5], [-120.95, 40.7], [-126.453, 43.252]
  ]);
});
test('missing, truncated and malformed map data are safe empty states', () => {
  for (const value of [undefined, '', '_p~iF', '!!!!!!', '~~~~~~~']) assert.deepEqual(decodePolyline(value), []);
});
test('feed includes running sports, sorts newest first, and preserves map absence', () => {
  const runs = runningActivities([
    { id: 1, sport_type: 'Run', start_date: '2026-10-01', map: { summary_polyline: '_p~iF~ps|U_ulLnnqC' } },
    { id: 2, sport_type: 'Ride', start_date: '2026-10-03' },
    { id: 3, sport_type: 'TrailRun', start_date: '2026-10-02' }
  ]);
  assert.deepEqual(runs.map(r => r.id), [3, 1]);
  assert.deepEqual(runs[0].coordinates, []);
  assert.equal(runs[1].coordinates.length, 2);
});
test('feed matching uses the authenticated athlete workout rather than supplied targets', () => {
  const runs = [{ id: 42, distance: 8000, total_elevation_gain: 120 }];
  const query = new URLSearchParams('lat=0&lon=0&radius=5000&distance=999&ascent=0');
  const result = targetForRun(runs, '42', query);
  assert.equal(result.params.get('distance'), '8000');
  assert.equal(result.params.get('ascent'), '120');
  assert.equal(targetForRun(runs, '999', query), null);
});
test('recorded route and reverse are not offered as new routes', () => {
  const points = [[0, 0], [.01, 0], [.01, .01], [0, 0]];
  assert.equal(retraces(points, points), true);
  assert.equal(retraces([...points].reverse(), points), true);
  assert.equal(retraces([[1, 1], [1.01, 1.01]], points), false);
  assert.equal(retraces(points, []), false);
});

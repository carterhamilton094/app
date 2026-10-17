import test from 'node:test';
import assert from 'node:assert/strict';
import { createRoutingService, waypointLoop } from '../routing.js';
import { meters } from '../routes.js';
const target = { lat: 0, lon: 0, radius: 5000, distance: 8000, ascent: 100 };
const path = { distance: 8000, ascend: 100, points: { coordinates: [[0, 0, 10], [.01, .01, 20], [.02, -.01, 10], [0, 0, 10]] } };
const errorCode = code => error => { assert.equal(error.code, `ROUTING_${code}`); return true; };

test('default loops use standard multi-point foot routing without flexible-mode options', async () => {
  const generate = createRoutingService({ key: 'test-only', fetcher: async url => {
    assert.equal(url.origin, 'https://graphhopper.com');
    const points = url.searchParams.getAll('point');
    assert.equal(points.length, 4);
    assert.equal(points[0], '0,0');
    assert.equal(points.at(-1), '0,0');
    assert.equal(url.searchParams.get('profile'), 'foot');
    assert.equal(url.searchParams.has('round_trip.distance'), false);
    assert.equal(url.searchParams.has('algorithm'), false);
    assert.equal(url.searchParams.has('ch.disable'), false);
    assert.equal(url.searchParams.get('elevation'), 'true');
    assert.equal(url.searchParams.get('points_encoded'), 'false');
    return Response.json({ paths: [path] });
  }});
  const result = await generate(target, [11]);
  assert.equal(result.length, 1);
  assert.equal(result[0].ascent, 100);
  assert.equal(result[0].coordinates[0][2], 10, 'elevation is preserved for GPX export');
});
test('blank keys fail without making a provider request', async () => {
  const generate = createRoutingService({ key: ' ', fetcher: () => { throw new Error('Must not run'); } });
  await assert.rejects(generate(target, [11]), errorCode('NOT_CONFIGURED'));
});
test('key failures and quota errors are distinct and never expose provider text', async () => {
  for (const [status, code] of [[401, 'ACCESS'], [403, 'ACCESS'], [429, 'QUOTA']]) {
    const generate = createRoutingService({ key: 'test-only', fetcher: async () => Response.json({ message: 'private-provider-data' }, { status }) });
    await assert.rejects(generate(target, [11]), error => {
      assert.equal(error.message.includes('private-provider-data'), false);
      return errorCode(code)(error);
    });
  }
  const generate = createRoutingService({ key: 'test-only', fetcher: async () => Response.json({ message: 'API key is invalid: private-provider-data' }, { status: 400 }) });
  await assert.rejects(generate(target, [11]), errorCode('ACCESS'));
});
test('no routable point for one seed does not discard a later viable loop', async () => {
  let calls = 0;
  const generate = createRoutingService({ key: 'test-only', fetcher: async () => ++calls === 1
    ? Response.json({ hints: [{ details: 'com.graphhopper.util.exceptions.PointNotFoundException' }] }, { status: 400 })
    : Response.json({ paths: [path] }) });
  assert.equal((await generate(target, [11, 29])).length, 1);
  assert.equal(calls, 2);
});
test('an unroutable area returns no matches rather than fabricated geometry', async () => {
  const generate = createRoutingService({ key: 'test-only', fetcher: async () => Response.json({ message: 'Cannot find point 0' }, { status: 400 }) });
  await assert.rejects(generate(target, [11, 29]), errorCode('NO_MATCH'));
});
test('missing elevation or malformed geometry is rejected', async () => {
  const invalid = [
    { ...path, ascend: undefined },
    { ...path, points: { coordinates: [[0, 0], [181, 1], [0, 0]] } },
    { ...path, points: { coordinates: 'not geometry' } }
  ];
  for (const item of invalid) {
    const generate = createRoutingService({ key: 'test-only', fetcher: async () => Response.json({ paths: [item] }) });
    await assert.rejects(generate(target, [11]), errorCode('INVALID_RESPONSE'));
  }
});
test('timeouts, service failures and rejected profile settings have clear outcomes', async () => {
  const timeout = createRoutingService({ key: 'test-only', fetcher: async () => { const e = new Error(); e.name = 'TimeoutError'; throw e; } });
  await assert.rejects(timeout(target, [11]), errorCode('TIMEOUT'));
  for (const [status, code] of [[500, 'UNAVAILABLE'], [400, 'REJECTED']]) {
    const generate = createRoutingService({ key: 'test-only', fetcher: async () => Response.json({ message: 'Request failed' }, { status }) });
    await assert.rejects(generate(target, [11]), errorCode(code));
  }
});

test('rejected requests return helpful provider details with keys, URLs and location removed', async () => {
  const key = 'private-key-for-testing';
  const localTarget = { ...target, lat: -27.4698, lon: 153.0251 };
  const generate = createRoutingService({ key, fetcher: async () => Response.json({
    message: `Unsupported parameter ch.disable for https://graphhopper.com/api/1/route?key=${key}&point=-27.4698,153.0251`,
    hints: [{ message: `Foot profile is unavailable; point=-27.4698,153.0251; api_key=${key}` }]
  }, { status: 400 }) });
  await assert.rejects(generate(localTarget, [11]), error => {
    assert.equal(error.code, 'ROUTING_REJECTED');
    assert.match(error.message, /Unsupported parameter ch.disable/);
    assert.match(error.message, /Foot profile is unavailable/);
    for (const privateValue of [key, 'https://graphhopper.com', '-27.4698', '153.0251']) {
      assert.equal(error.message.includes(privateValue), false, `Must not expose ${privateValue}`);
    }
    return true;
  });
});
test('provider diagnostic sanitization also handles encoded keys and control characters', async () => {
  const { safeProviderDetail } = await import('../routing.js');
  const key = 'private/key+value';
  const result = safeProviderDetail({ message: `Invalid parameter\nkey=${encodeURIComponent(key)} location 12.3456,78.9012` }, key, { lat: 12.3456, lon: 78.9012 });
  assert.equal(result.includes(key), false);
  assert.equal(result.includes(encodeURIComponent(key)), false);
  assert.equal(result.includes('12.3456'), false);
  assert.equal(result.includes('\n'), false);
});

test('explicit round_trip mode retains flexible routing for entitled accounts only', async () => {
  const generate = createRoutingService({ key: 'test-only', mode: 'round_trip', fetcher: async url => {
    assert.deepEqual(url.searchParams.getAll('point'), ['0,0']);
    assert.equal(url.searchParams.get('algorithm'), 'round_trip');
    assert.equal(url.searchParams.get('round_trip.distance'), '8000');
    assert.equal(url.searchParams.get('ch.disable'), 'true');
    return Response.json({ paths: [path] });
  }});
  assert.equal((await generate(target, [11])).length, 1);
});
test('search anchors stay inside the home radius, close at home and vary by seed', () => {
  const local = { ...target, lat: -27.4698, lon: 153.0251, distance: 30000, radius: 1000 };
  const first = waypointLoop(local, 11), second = waypointLoop(local, 29);
  assert.deepEqual(first[0], [local.lat, local.lon]);
  assert.deepEqual(first.at(-1), first[0]);
  assert.notDeepEqual(first[1], second[1]);
  for (const [lat, lon] of first) {
    assert.ok(meters([local.lon, local.lat], [lon, lat]) <= local.radius * 0.801);
  }
});
test('standard searches still reject real paths outside radius or mismatching workout effort', async () => {
  const outside = { ...path, points: { coordinates: [[0, 0], [1, 1], [0, 0]] } };
  const tooLong = { ...path, distance: 14000 };
  const tooHilly = { ...path, ascend: 500 };
  for (const invalid of [outside, tooLong, tooHilly]) {
    const generate = createRoutingService({ key: 'test-only', fetcher: async () => Response.json({ paths: [invalid] }) });
    await assert.rejects(generate(target, [11]), errorCode('NO_MATCH'));
  }
});
test('invalid routing mode fails before spending provider credits', async () => {
  const generate = createRoutingService({ key: 'test-only', mode: 'unknown', fetcher: () => { throw new Error('Must not run'); } });
  await assert.rejects(generate(target, [11]), errorCode('MODE'));
});

test('later standard searches calibrate waypoint size from the observed route length', async () => {
  const anchors = [];
  const generate = createRoutingService({ key: 'test-only', fetcher: async url => {
    const [lat, lon] = url.searchParams.getAll('point')[1].split(',').map(Number);
    anchors.push(meters([0, 0], [lon, lat]));
    return Response.json({ paths: [{ ...path, distance: anchors.length === 1 ? 4000 : 8000 }] });
  }});
  const routes = await generate(target, [11, 29]);
  assert.equal(routes[0].distance, 8000);
  assert.ok(anchors[1] > anchors[0] * 1.5, 'short first path enlarges subsequent search anchors');
  assert.equal(anchors.length, 2, 'does not add extra quota-consuming requests');
});

test('no-match exception preserves only usable, novel closest options for the feed', async () => {
  const hilly = { ...path, ascend: 500 };
  const generate = createRoutingService({ key: 'test-only', fetcher: async () => Response.json({ paths: [hilly] }) });
  await assert.rejects(generate(target, [11]), error => {
    assert.equal(error.code, 'ROUTING_NO_MATCH');
    assert.equal(error.suggestions.length, 1);
    assert.equal(error.suggestions[0].ascent, 500);
    return true;
  });
  await assert.rejects(generate(target, [11], hilly.points.coordinates), error => {
    assert.equal(error.suggestions.length, 0, 'recorded run is not offered as a new alternative');
    return true;
  });
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRoutingService } from '../routing.js';
const target = { lat: 0, lon: 0, radius: 5000, distance: 8000, ascent: 100 };
const path = { distance: 8000, ascend: 100, points: { coordinates: [[0, 0, 10], [.01, .01, 20], [.02, -.01, 10], [0, 0, 10]] } };
const errorCode = code => error => { assert.equal(error.code, `ROUTING_${code}`); return true; };

test('loop requests use foot routing, elevation, flexible mode and unencoded coordinates', async () => {
  const generate = createRoutingService({ key: 'test-only', fetcher: async url => {
    assert.equal(url.origin, 'https://graphhopper.com');
    assert.equal(url.searchParams.get('point'), '0,0');
    assert.equal(url.searchParams.get('profile'), 'foot');
    assert.equal(url.searchParams.get('round_trip.distance'), '8000');
    assert.equal(url.searchParams.get('ch.disable'), 'true');
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
  assert.deepEqual(await generate(target, [11, 29]), []);
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

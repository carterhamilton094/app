import test from 'node:test';
import assert from 'node:assert/strict';

// All provider responses are mocked; this exercises real local HTTP + OAuth/session flow.
test('authenticated feed returns map geometry and two cached workout-matched alternatives', async t => {
  const nativeFetch = globalThis.fetch;
  Object.assign(process.env, {
    PORT: '0', STRAVA_CLIENT_ID: 'test-client', STRAVA_CLIENT_SECRET: 'test-only',
    PUBLIC_URL: 'https://runways.test', GRAPHHOPPER_KEY: 'test-only'
  });
  let routingCalls = 0;
  let tooHilly = false;
  globalThis.fetch = async (input) => {
    const url = new URL(input);
    if (url.pathname === '/oauth/token') return Response.json({ access_token: 'mock-access', refresh_token: 'mock-refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 });
    if (url.pathname === '/api/v3/athlete/activities') return Response.json([
      { id: 42, name: 'Test run', sport_type: 'Run', distance: 8000, total_elevation_gain: 100,
        moving_time: 2400, start_date: '2026-10-17T00:00:00Z', map: { summary_polyline: '_p~iF~ps|U_ulLnnqC' } }
    ]);
    if (url.hostname === 'graphhopper.com') {
      routingCalls++;
      assert.equal(url.searchParams.has('ch.disable'), false);
      assert.equal(url.searchParams.has('algorithm'), false);
      assert.equal(url.searchParams.getAll('point').length, 4);
      assert.equal(url.searchParams.get('point'), '0,0');
      const shift = routingCalls * .001;
      return Response.json({ paths: [{ distance: 8000, ascend: tooHilly ? 500 : 100,
        points: { coordinates: [[0, 0], [.01 + shift, .01], [.015, -.01 - shift], [0, 0]] } }] });
    }
    throw new Error('Unexpected upstream request');
  };
  let server;
  try { ({ server } = await import('../index.js')); }
  finally { globalThis.fetch = nativeFetch; }
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  if (!server.listening) await new Promise(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const health = await nativeFetch(`${base}/health`);
  assert.equal((await health.json()).routingMode, 'waypoints');
  const unauthorized = await nativeFetch(`${base}/runs/42/alternatives`);
  assert.equal(unauthorized.status, 401);
  const authorization = await nativeFetch(`${base}/auth/strava`, { redirect: 'manual' });
  const location = new URL(authorization.headers.get('location'));
  const state = location.searchParams.get('state');
  const callback = await nativeFetch(`${base}/auth/callback?state=${state}&code=mock&scope=read,activity:read_all`, {
    headers: { cookie: `runways_state=${state}` }, redirect: 'manual'
  });
  assert.equal(callback.status, 302);
  const ticket = new URL(callback.headers.get('location')).searchParams.get('ticket');
  const exchange = await nativeFetch(`${base}/auth/exchange?ticket=${ticket}`);
  const { session } = await exchange.json();
  const headers = { Authorization: `Bearer ${session}` };
  const feed = await nativeFetch(`${base}/runs`, { headers });
  const runs = await feed.json();
  assert.equal(runs[0].coordinates.length, 2);
  const path = `${base}/runs/42/alternatives?lat=0&lon=0&radius=5000&distance=999&ascent=0`;
  const matches = await nativeFetch(path, { headers });
  assert.equal(matches.status, 200);
  const body = await matches.json();
  assert.equal(body.routes.length, 2);
  assert.equal(body.routes[0].distance, 8000);
  assert.equal(body.routes[0].coordinates.length, 4);
  assert.equal(routingCalls, 4);
  const cached = await nativeFetch(path, { headers });
  assert.deepEqual(await cached.json(), body);
  assert.equal(routingCalls, 4, 'repeat feed loads reuse cached routes');
  const missing = await nativeFetch(`${base}/runs/999/alternatives?lat=0&lon=0&radius=5000`, { headers });
  assert.equal(missing.status, 404, 'only this athlete’s activities may be matched');
  const invalid = await nativeFetch(`${base}/runs/42/alternatives?lat=0&lon=0&radius=-1`, { headers });
  assert.equal(invalid.status, 400);
  tooHilly = true;
  const noMatch = await nativeFetch(`${base}/runs/42/alternatives?lat=0&lon=0&radius=6000`, { headers });
  assert.equal(noMatch.status, 422);
  const failure = await noMatch.json();
  assert.equal(failure.code, 'ROUTING_NO_MATCH');
  assert.match(failure.error, /Distance-matched routes climbed 500–500 m/);
  assert.match(failure.error, /target is 100 m/);
});

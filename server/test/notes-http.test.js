import test from 'node:test';
import assert from 'node:assert/strict';

test('activity notes require opt-in write scope, enforce ownership and preserve existing descriptions', async t => {
  const nativeFetch = globalThis.fetch;
  Object.assign(process.env, { PORT: '0', STRAVA_CLIENT_ID: 'test-client', STRAVA_CLIENT_SECRET: 'test-only', PUBLIC_URL: 'https://runways.test' });
  delete process.env.GRAPHHOPPER_KEY;
  let description = 'My original training notes.';
  let updates = 0, refreshes = 0, historyCalls = 0;
  globalThis.fetch = async (input, options = {}) => {
    const url = new URL(input);
    if (url.pathname === '/oauth/token') {
      if (options.body.get('grant_type') === 'refresh_token') {
        refreshes++;
        return Response.json({ access_token: 'refreshed', refresh_token: 'refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 });
      }
      return Response.json({ access_token: 'mock', refresh_token: 'refresh', expires_at: 0, athlete: { id: 7 } });
    }
    if (url.pathname === '/api/v3/athlete/activities') {
      historyCalls++;
      return Response.json([]);
    }
    if (url.pathname.startsWith('/api/v3/activities/')) {
      const id = Number(url.pathname.split('/').at(-1));
      if (options.method === 'PUT') {
        updates++;
        assert.equal(id, 42);
        description = options.body.get('description');
        return Response.json({ id, description });
      }
      return Response.json({ id, athlete: { id: id === 43 ? 99 : 7 }, sport_type: id === 44 ? 'Ride' : 'Run', description });
    }
    throw new Error('Unexpected upstream request');
  };
  let server;
  try { ({ server } = await import('../index.js')); }
  finally { globalThis.fetch = nativeFetch; }
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  if (!server.listening) await new Promise(resolve => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  async function login(write) {
    const auth = await nativeFetch(`${base}/auth/strava${write ? '?write=1' : ''}`, { redirect: 'manual' });
    const request = new URL(auth.headers.get('location'));
    assert.equal(request.searchParams.get('scope').includes('activity:write'), write);
    const state = request.searchParams.get('state');
    const scopes = write ? 'read,activity:read_all,activity:write' : 'read,activity:read_all';
    const callback = await nativeFetch(`${base}/auth/callback?state=${state}&code=mock&scope=${scopes}`, { redirect: 'manual', headers: { cookie: `runways_state=${state}` } });
    const ticket = new URL(callback.headers.get('location')).searchParams.get('ticket');
    const response = await nativeFetch(`${base}/auth/exchange?ticket=${ticket}`);
    const { session } = await response.json();
    return { Authorization: `Bearer ${session}` };
  }
  const readonly = await login(false);
  let response = await nativeFetch(`${base}/runs/42/note`, { method: 'POST', headers: readonly });
  assert.equal(response.status, 403);
  assert.equal(updates, 0);
  const writable = await login(true);
  const account = await nativeFetch(`${base}/account`, { headers: writable });
  assert.deepEqual(await account.json(), { athleteID: 7, writeAuthorized: true, routingConfigured: false });
  response = await nativeFetch(`${base}/runs/43/note`, { method: 'POST', headers: writable });
  assert.equal(response.status, 404, 'another athlete’s activity cannot be changed');
  assert.equal(refreshes, 1);
  const afterRefresh = await nativeFetch(`${base}/account`, { headers: writable });
  assert.equal((await afterRefresh.json()).athleteID, 7, 'athlete identity survives token refresh');
  response = await nativeFetch(`${base}/runs/44/note`, { method: 'POST', headers: writable });
  assert.equal(response.status, 404, 'non-running activities cannot be changed');
  assert.equal(updates, 0);
  response = await nativeFetch(`${base}/runs/42/note`, { headers: writable });
  assert.equal(response.status, 404, 'GET requests must never mutate an activity');
  response = await nativeFetch(`${base}/runs/42/note`, { method: 'POST', headers: writable });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).description, 'My original training notes.\n\nExplored a new loop with Runways.');
  response = await nativeFetch(`${base}/runs/42/note`, { method: 'POST', headers: writable });
  assert.equal((await response.json()).updated, false);
  assert.equal(updates, 1, 'repeating an update does not duplicate or repost the note');
  response = await nativeFetch(`${base}/history?before=bad`, { headers: writable });
  assert.equal(response.status, 400);
  const historyURL = `${base}/history?before=1700000000`;
  response = await nativeFetch(historyURL, { headers: writable });
  assert.deepEqual(await response.json(), { runs: [], nextBefore: null });
  await nativeFetch(historyURL, { headers: writable });
  assert.equal(historyCalls, 1, 'repeated history requests use the account cache');
  response = await nativeFetch(`${base}/runs/42/alternatives?lat=0&lon=0&radius=5000`, { headers: writable });
  assert.equal(response.status, 503);
  assert.match((await response.json()).error, /Strava runs and maps still work/);
});

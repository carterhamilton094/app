import http from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { parseTarget } from './routes.js';
import { createRoutingService, RoutingError } from './routing.js';
import { runningActivities, targetForRun, appendRouteNote, historyPage } from './activities.js';
const { STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET, PUBLIC_URL, GRAPHHOPPER_KEY, GRAPHHOPPER_ROUTING_MODE } = process.env;
const port = Number(process.env.PORT || 3000);
const upstreamFetch = fetch;
const routingMode = GRAPHHOPPER_ROUTING_MODE || 'waypoints';
const generateRoutes = createRoutingService({ key: GRAPHHOPPER_KEY, fetcher: upstreamFetch, mode: routingMode });
// Development storage only. Restarting the server requires reconnecting Strava.
const states = new Map(), tickets = new Map(), sessions = new Map(), limits = new Map();
const opaque = () => randomBytes(32).toString('hex');
const send = (res, status, body) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' }); res.end(JSON.stringify(body)); };
const redirect = (res, location) => { res.writeHead(302, { Location: location, 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' }); res.end(); };
async function json(url, options) {
  const response = await upstreamFetch(url, { ...options, signal: AbortSignal.timeout(20000) });
  if (!response.ok) throw new Error(`Upstream service returned ${response.status}`);
  return response.json();
}
async function stravaToken(fields) {
  return json('https://www.strava.com/oauth/token', { method: 'POST', body: new URLSearchParams({ client_id: STRAVA_CLIENT_ID, client_secret: STRAVA_CLIENT_SECRET, ...fields }) });
}
async function access(session) {
  if (session.tokens.expires_at * 1000 < Date.now() + 60000) {
    session.athleteID ??= session.tokens.athlete?.id;
    session.refresh ??= stravaToken({ grant_type: 'refresh_token', refresh_token: session.tokens.refresh_token })
      .then(tokens => { session.tokens = tokens; })
      .finally(() => { session.refresh = null; });
    await session.refresh;
  }
  return session.tokens.access_token;
}
async function athleteRuns(session) {
  if (session.runs && session.runs.expires > Date.now()) return session.runs.value;
  if (!session.loadingRuns) {
    session.loadingRuns = (async () => {
      const activities = await json('https://www.strava.com/api/v3/athlete/activities?per_page=100', {
        headers: { Authorization: `Bearer ${await access(session)}` }
      });
      const value = runningActivities(activities);
      session.runs = { value, expires: Date.now() + 300000 };
      return value;
    })().finally(() => { session.loadingRuns = null; });
  }
  return session.loadingRuns;
}
setInterval(() => {
  for (const map of [states, tickets, sessions, limits]) for (const [key, value] of map) if (value.expires < Date.now()) map.delete(key);
}, 60000).unref();
export const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const noteMatch = url.pathname.match(/^\/runs\/(\d+)\/note$/);
    if (req.method !== 'GET' && !(req.method === 'POST' && noteMatch)) return send(res, 405, { error: 'Method not allowed' });
    if (url.pathname === '/health') return send(res, 200, { status: 'ok', stravaConfigured: Boolean(STRAVA_CLIENT_ID && STRAVA_CLIENT_SECRET && PUBLIC_URL), routingConfigured: Boolean(GRAPHHOPPER_KEY?.trim()), routingMode });
    if (url.pathname === '/auth/strava') {
      if (!STRAVA_CLIENT_ID || !STRAVA_CLIENT_SECRET || !PUBLIC_URL) return send(res, 503, { error: 'Configure Strava on the server first' });
      const write = url.searchParams.get('write') === '1';
      const state = opaque(); states.set(state, { write, expires: Date.now() + 600000 });
      const auth = new URL('https://www.strava.com/oauth/authorize');
      auth.search = new URLSearchParams({ client_id: STRAVA_CLIENT_ID, redirect_uri: `${PUBLIC_URL.replace(/\/$/, '')}/auth/callback`, response_type: 'code', approval_prompt: write ? 'force' : 'auto', scope: write ? 'read,activity:read_all,activity:write' : 'read,activity:read_all', state });
      res.setHeader('Set-Cookie', `runways_state=${state}; HttpOnly; Secure; SameSite=Lax; Path=/auth; Max-Age=600`);
      return redirect(res, auth.toString());
    }
    if (url.pathname === '/auth/callback') {
      const state = url.searchParams.get('state'), pending = states.get(state);
      const cookie = req.headers.cookie?.split(';').map(c => c.trim()).find(c => c.startsWith('runways_state='))?.slice(14);
      if (!pending || pending.expires < Date.now() || !cookie || cookie.length !== state.length || !timingSafeEqual(Buffer.from(cookie), Buffer.from(state))) return send(res, 400, { error: 'Invalid or expired authorization state' });
      states.delete(state);
      if (!url.searchParams.get('code') || !url.searchParams.get('scope')?.split(',').includes('activity:read_all')) return send(res, 400, { error: 'Activity access was not granted. Reconnect and allow activity access.' });
      const tokens = await stravaToken({ grant_type: 'authorization_code', code: url.searchParams.get('code') });
      const scopes = url.searchParams.get('scope').split(',').filter(scope => scope !== 'activity:write' || pending.write);
      const ticket = opaque(); tickets.set(ticket, { tokens, scopes, expires: Date.now() + 60000 });
      return redirect(res, `runways://connected?ticket=${ticket}`);
    }
    if (url.pathname === '/auth/exchange') {
      const ticket = url.searchParams.get('ticket'), entry = tickets.get(ticket); tickets.delete(ticket);
      if (!entry || entry.expires < Date.now()) return send(res, 401, { error: 'Connection ticket expired' });
      const session = opaque(); sessions.set(session, { tokens: entry.tokens, scopes: entry.scopes, expires: Date.now() + 30 * 86400000 });
      return send(res, 200, { session });
    }
    const key = req.headers.authorization?.replace(/^Bearer /, ''), session = sessions.get(key);
    if (!session || session.expires < Date.now()) return send(res, 401, { error: 'Reconnect Strava to continue' });
    if (url.pathname === '/account') {
      return send(res, 200, {
        athleteID: session.tokens.athlete?.id ?? session.athleteID,
        writeAuthorized: session.scopes?.includes('activity:write') ?? false,
        routingConfigured: Boolean(GRAPHHOPPER_KEY?.trim())
      });
    }
    if (url.pathname === '/history') {
      const before = Number(url.searchParams.get('before'));
      if (!Number.isSafeInteger(before) || before < 946684800 || before > Math.floor(Date.now() / 1000) + 86400) {
        return send(res, 400, { error: 'Invalid history date' });
      }
      session.history ??= new Map();
      const cached = session.history.get(before);
      if (cached) return send(res, 200, cached);
      if (session.history.size >= 100) return send(res, 429, { error: 'History limit reached for this session. Reconnect to continue.' });
      const activities = await json(`https://www.strava.com/api/v3/athlete/activities?per_page=100&before=${before}`, {
        headers: { Authorization: `Bearer ${await access(session)}` }
      });
      const page = historyPage(activities);
      session.history.set(before, page);
      return send(res, 200, page);
    }
    if (noteMatch && req.method === 'POST') {
      if (!session.scopes?.includes('activity:write')) return send(res, 403, { error: 'Enable activity notes in Settings and grant Strava activity-write permission first.' });
      if (session.noteInFlight) return send(res, 429, { error: 'Another activity update is in progress. Try again shortly.' });
      session.noteInFlight = true;
      try {
        const activityID = noteMatch[1];
        const activity = await json(`https://www.strava.com/api/v3/activities/${activityID}`, {
          headers: { Authorization: `Bearer ${await access(session)}` }
        });
        const athleteID = session.tokens.athlete?.id ?? session.athleteID;
        if (!athleteID || activity.athlete?.id !== athleteID || !['Run', 'TrailRun', 'VirtualRun'].includes(activity.sport_type)) {
          return send(res, 404, { error: 'Completed run not found for this Strava account' });
        }
        const description = appendRouteNote(activity.description);
        const updated = description !== (activity.description ?? '');
        if (updated) {
          await json(`https://www.strava.com/api/v3/activities/${activityID}`, {
            method: 'PUT', headers: { Authorization: `Bearer ${await access(session)}` },
            body: new URLSearchParams({ description })
          });
        }
        return send(res, 200, { updated, description });
      } finally { session.noteInFlight = false; }
    }
    if (url.pathname === '/disconnect') {
      await json('https://www.strava.com/oauth/deauthorize', { method: 'POST', body: new URLSearchParams({ access_token: await access(session) }) });
      sessions.delete(key); return send(res, 200, { session: '' });
    }
    if (url.pathname === '/runs') {
      return send(res, 200, await athleteRuns(session));
    }
    const match = url.pathname.match(/^\/runs\/(\d+)\/alternatives$/);
    if (match) {
      if (!GRAPHHOPPER_KEY?.trim()) throw new RoutingError('NOT_CONFIGURED');
      const workout = targetForRun(await athleteRuns(session), match[1], url.searchParams);
      if (!workout) return send(res, 404, { error: 'Run not found in your recent Strava activities' });
      let target;
      try { target = parseTarget(workout.params); }
      catch { return send(res, 400, { error: 'Set a valid home and radius. Matching supports 2–30 km runs with up to 800 m climbing.' }); }
      session.matches ??= new Map();
      const cacheKey = JSON.stringify([match[1], target]);
      const cached = session.matches.get(cacheKey);
      if (cached && cached.expires > Date.now()) return send(res, 200, { routes: await cached.result });
      const now = Date.now();
      if (!session.feedBudget || session.feedBudget.expires <= now) session.feedBudget = { count: 0, expires: now + 600000 };
      if (session.feedBudget.count >= 12 || (session.activeMatches || 0) >= 3) {
        return send(res, 429, { error: 'Route searches are busy or at the current limit. Retry shortly; search allowance resets every ten minutes.' });
      }
      // Cache in-flight requests too, so revisiting a card does not spend more quota.
      session.feedBudget.count++;
      session.activeMatches = (session.activeMatches || 0) + 1;
      const result = generateRoutes(target, [11, 29, 47, 83], workout.run.coordinates)
        .then(routes => routes.slice(0, 2))
        .catch(error => { session.matches.delete(cacheKey); throw error; })
        .finally(() => { session.activeMatches--; });
      session.matches.set(cacheKey, { result, expires: now + 600000 });
      // Keep per-athlete memory bounded as home settings change.
      if (session.matches.size > 50) session.matches.delete(session.matches.keys().next().value);
      return send(res, 200, { routes: await result });
    }
    if (url.pathname === '/routes') {
      if (!GRAPHHOPPER_KEY?.trim()) throw new RoutingError('NOT_CONFIGURED');
      let target; try { target = parseTarget(url.searchParams); } catch (e) { return send(res, 400, { error: e.message }); }
      const rate = limits.get(key);
      if (rate && rate.expires > Date.now()) return send(res, 429, { error: 'Please wait one minute before generating more routes' });
      limits.set(key, { expires: Date.now() + 60000 });
      return send(res, 200, { routes: await generateRoutes(target, [11, 29, 47, 83, 107, 139]) });
    }
    send(res, 404, { error: 'Not found' });
  } catch (error) {
    if (error instanceof RoutingError) return send(res, error.status, { error: error.message, code: error.code });
    send(res, 502, { error: 'The upstream service could not complete this request. Check server credentials, provider quota and connectivity.' });
  }
}).listen(port, '0.0.0.0', () => console.log(`Runways backend listening on ${port}`));

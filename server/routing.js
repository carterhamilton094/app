import { selectRoutes, retraces } from './routes.js';

const failures = {
  NOT_CONFIGURED: [503, 'Route discovery is not available yet. Your Strava runs and maps still work.'],
  ACCESS: [503, 'The route service could not authenticate. Check the GraphHopper key and its routing access in Render.'],
  QUOTA: [503, 'The route service has reached its request allowance. Please try again later.'],
  TIMEOUT: [504, 'The route service took too long to respond. Please try again.'],
  UNAVAILABLE: [502, 'The route service is temporarily unavailable. Please try again.'],
  REJECTED: [502, 'The route service rejected this search.'],
  INVALID_RESPONSE: [502, 'The route service returned incomplete route or elevation data. Please try again.']
};
export class RoutingError extends Error {
  constructor(reason, detail = '') {
    const [status, message] = failures[reason] ?? failures.UNAVAILABLE;
    super(detail ? `${message} GraphHopper: ${detail}` : message);
    this.status = status;
    this.code = `ROUTING_${reason}`;
  }
}
// Surface provider diagnostics without leaking query URLs, API keys or home coordinates.
export function safeProviderDetail(result, key, target) {
  const hints = Array.isArray(result?.hints) ? result.hints : [];
  const messages = [result?.message, ...hints.map(hint => hint?.message)]
    .filter(message => typeof message === 'string' && message.trim());
  let text = [...new Set(messages)].join(' · ');
  if (!text) return '';
  for (const secret of [key, encodeURIComponent(key ?? '')]) {
    if (secret) text = text.split(secret).join('[redacted]');
  }
  text = text.replace(/https?:\/\/[^\s<>"']+/gi, '[provider URL]')
    .replace(/\b(?:api[_ -]?key|access[_ -]?token|client[_ -]?secret)\s*[:=]\s*["']?[^\s"',;]+/gi, '[credential redacted]')
    .replace(/-?\d{1,3}(?:\.\d+)?\s*,\s*-?\d{1,3}(?:\.\d+)?/g, '[location]')
    .replace(/\b(?:lat(?:itude)?|lon(?:gitude)?|point)\s*[:=]\s*-?\d+(?:\.\d+)?/gi, '[location]');
  for (const coordinate of [target?.lat, target?.lon]) {
    const value = String(coordinate);
    if (value.includes('.') && value.length >= 5) text = text.split(value).join('[location]');
  }
  return text.replace(/[\x00-\x1f\x7f]/g, ' ').slice(0, 450);
}
function validPath(path) {
  const coordinates = path?.points?.coordinates;
  return Number.isFinite(path?.distance) && path.distance > 0 &&
    Number.isFinite(path?.ascend) && path.ascend >= 0 &&
    Array.isArray(coordinates) && coordinates.length >= 3 &&
    coordinates.every(point => Array.isArray(point) && point.length >= 2 && point.every(Number.isFinite) && Math.abs(point[0]) <= 180 && Math.abs(point[1]) <= 90);
}
export function createRoutingService({ key, fetcher = fetch }) {
  return async function generateRoutes(target, seeds, original = []) {
    if (!key?.trim()) throw new RoutingError('NOT_CONFIGURED');
    const paths = [];
    for (const seed of seeds) {
      const endpoint = new URL('https://graphhopper.com/api/1/route');
      endpoint.search = new URLSearchParams({
        key, point: `${target.lat},${target.lon}`, profile: 'foot',
        algorithm: 'round_trip', 'round_trip.distance': String(target.distance),
        'round_trip.seed': String(seed), 'ch.disable': 'true',
        elevation: 'true', points_encoded: 'false', instructions: 'false'
      });
      let response;
      try {
        response = await fetcher(endpoint, { signal: AbortSignal.timeout(20000) });
      } catch (error) {
        throw new RoutingError(['TimeoutError', 'AbortError'].includes(error.name) ? 'TIMEOUT' : 'UNAVAILABLE');
      }
      if ([401, 403].includes(response.status)) throw new RoutingError('ACCESS');
      if (response.status === 429) throw new RoutingError('QUOTA');
      if (response.status >= 500) throw new RoutingError('UNAVAILABLE');
      let result;
      try { result = await response.json(); }
      catch { throw new RoutingError('INVALID_RESPONSE'); }
      if (!response.ok) {
        // Inspect upstream diagnostics to distinguish an unroutable point, but never
        // echo provider text: it can contain key-bearing URLs and private locations.
        const hints = Array.isArray(result?.hints) ? result.hints : [];
        const diagnostic = [result?.message, ...hints.map(h => `${h.details ?? ''} ${h.message ?? ''}`)].join(' ');
        if (/invalid.*(?:api.?key|key)|(?:api.?key|key).*invalid|not authorized/i.test(diagnostic)) throw new RoutingError('ACCESS');
        const noPath = /PointNotFoundException|ConnectionNotFoundException|cannot find point|cannot find.*route|connection between locations not found/i.test(diagnostic);
        if (response.status === 400 && noPath) continue;
        throw new RoutingError('REJECTED', safeProviderDetail(result, key, target));
      }
      if (!Array.isArray(result?.paths)) throw new RoutingError('INVALID_RESPONSE');
      const valid = result.paths.filter(validPath);
      if (result.paths.length && !valid.length) throw new RoutingError('INVALID_RESPONSE');
      for (const [index, path] of valid.entries()) {
        paths.push({ id: `${seed}-${index}`, name: `Discovery loop ${paths.length + 1}`,
          distance: path.distance, ascent: path.ascend, coordinates: path.points.coordinates });
      }
    }
    const distinct = paths.filter(path => !retraces(path.coordinates, original));
    return selectRoutes(distinct, target);
  };
}

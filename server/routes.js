export function meters(a, b) {
  const r = Math.PI / 180, dLat = (b[1] - a[1]) * r, dLon = (b[0] - a[0]) * r;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * r) * Math.cos(b[1] * r) * Math.sin(dLon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}
export function score(route, distance, ascent) {
  return Math.max(0, 1 - .7 * Math.abs(route.distance - distance) / Math.max(distance, 1) - .3 * Math.abs(route.ascent - ascent) / Math.max(ascent, 30));
}
export function routeRejections(path, { lat, lon, radius, distance, ascent }) {
  const coordinates = path?.coordinates;
  if (!Number.isFinite(path?.distance) || !Number.isFinite(path?.ascent) ||
      !Array.isArray(coordinates) || coordinates.length < 3 || coordinates.some(point =>
        !Array.isArray(point) || point.length < 2 || !point.every(Number.isFinite) || Math.abs(point[0]) > 180 || Math.abs(point[1]) > 90)) return ['geometry'];
  const reasons = [];
  if (coordinates.some(point => meters([lon, lat], point) > radius)) reasons.push('radius');
  if (meters([lon, lat], coordinates[0]) > 200 || meters(coordinates[0], coordinates.at(-1)) > 200) reasons.push('closure');
  if (Math.abs(path.distance - distance) / distance > .2) reasons.push('distance');
  if (Math.abs(path.ascent - ascent) > Math.max(40, ascent * .35)) reasons.push('climb');
  return reasons;
}
export function selectRoutes(paths, target) {
  const unique = new Set();
  return paths.filter(path => {
    if (routeRejections(path, target).length) return false;
    const key = path.coordinates.map(point => point.slice(0, 2).map(n => n.toFixed(4)).join(',')).sort().join(';');
    if (unique.has(key)) return false;
    unique.add(key); return true;
  }).sort((a, b) => score(b, target.distance, target.ascent) - score(a, target.distance, target.ascent)).slice(0, 4);
}
export function noMatchMessage(paths, target, original = []) {
  if (!paths.length) return 'No walkable loop was found from this start. Try setting home on a nearby public street or path.';
  const assessed = paths.map(path => ({ path, reasons: routeRejections(path, target) }));
  const inside = assessed.filter(item => !item.reasons.some(reason => ['geometry', 'closure', 'radius'].includes(reason)));
  if (!inside.length) {
    if (assessed.every(item => item.reasons.includes('radius'))) return `All ${paths.length} candidate paths left your ${(target.radius / 1000).toFixed(1)} km home radius. Increase the radius or choose a different starting point.`;
    return 'The paths found did not form a loop near home inside your radius. Try a nearby public street or a larger radius.';
  }
  const distanceMatched = inside.filter(item => !item.reasons.includes('distance'));
  if (!distanceMatched.length) {
    const distances = inside.map(item => item.path.distance / 1000);
    return `Routes inside your radius were ${Math.min(...distances).toFixed(1)}–${Math.max(...distances).toFixed(1)} km. Your target is ${(target.distance / 1000).toFixed(1)} km (accepted ${(target.distance * .8 / 1000).toFixed(1)}–${(target.distance * 1.2 / 1000).toFixed(1)} km). Try a different distance or starting point.`;
  }
  const effortMatched = distanceMatched.filter(item => !item.reasons.includes('climb'));
  if (!effortMatched.length) {
    const ascents = distanceMatched.map(item => item.path.ascent);
    const tolerance = Math.max(40, target.ascent * .35);
    return `Distance-matched routes climbed ${Math.round(Math.min(...ascents))}–${Math.round(Math.max(...ascents))} m. Your target is ${Math.round(target.ascent)} m (accepted ${Math.round(Math.max(0, target.ascent - tolerance))}–${Math.round(target.ascent + tolerance)} m). Adjust the climbing target or starting point.`;
  }
  if (original.length && effortMatched.every(item => retraces(item.path.coordinates, original))) return 'The matching paths retraced your recorded run. Try a different home radius or use Plan to explore another workout target.';
  return 'No distinct loops matched all search rules. Try another starting point or workout target.';
}
export function parseTarget(params) {
  const limits = { lat: [-90, 90], lon: [-180, 180], distance: [2000, 30000], ascent: [0, 800], radius: [1000, 20000] };
  const result = {};
  for (const [key, [min, max]] of Object.entries(limits)) {
    if (!params.has(key) || params.get(key).trim() === '') throw new Error(`Missing ${key}`);
    const value = Number(params.get(key));
    if (!Number.isFinite(value) || value < min || value > max) throw new Error(`Invalid ${key}`);
    result[key] = value;
  }
  return result;
}

// Reject a candidate that mostly retraces the recorded run, including its reverse.
export function retraces(candidate, original) {
  if (!original?.length || !candidate?.length) return false;
  const sample = points => points.filter((_, i) => i % Math.max(1, Math.floor(points.length / 100)) === 0);
  const left = sample(candidate), right = sample(original);
  const coverage = (a, b) => a.filter(p => b.some(q => meters(p, q) < 60)).length / a.length;
  return coverage(left, right) > .85 && coverage(right, left) > .85;
}

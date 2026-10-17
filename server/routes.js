export function meters(a, b) {
  const r = Math.PI / 180, dLat = (b[1] - a[1]) * r, dLon = (b[0] - a[0]) * r;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * r) * Math.cos(b[1] * r) * Math.sin(dLon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}
export function score(route, distance, ascent) {
  return Math.max(0, 1 - .7 * Math.abs(route.distance - distance) / Math.max(distance, 1) - .3 * Math.abs(route.ascent - ascent) / Math.max(ascent, 30));
}
export function selectRoutes(paths, { lat, lon, radius, distance, ascent }) {
  const unique = new Set();
  return paths.filter(p => {
    const coords = p.coordinates;
    if (!Number.isFinite(p.distance) || !Number.isFinite(p.ascent) || !coords?.length || coords.some(c => c.length < 2 || !c.every(Number.isFinite))) return false;
    if (coords.some(c => meters([lon, lat], c) > radius)) return false;
    if (meters([lon, lat], coords[0]) > 200 || meters(coords[0], coords.at(-1)) > 200) return false;
    if (Math.abs(p.distance - distance) / distance > .2 || Math.abs(p.ascent - ascent) > Math.max(40, ascent * .35)) return false;
    const key = coords.map(c => c.slice(0, 2).map(n => n.toFixed(4)).join(',')).sort().join(';');
    if (unique.has(key)) return false;
    unique.add(key); return true;
  }).sort((a, b) => score(b, distance, ascent) - score(a, distance, ascent)).slice(0, 4);
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

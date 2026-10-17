// Strava summary polylines use Google's signed delta encoding at 1e5 precision.
export function decodePolyline(encoded) {
  if (!encoded || typeof encoded !== 'string') return [];
  let index = 0, lat = 0, lon = 0;
  const points = [];
  const component = () => {
    let value = 0, shift = 0, byte;
    do {
      if (index >= encoded.length || shift > 30) throw new Error('Malformed polyline');
      byte = encoded.charCodeAt(index++) - 63;
      if (byte < 0 || byte > 63) throw new Error('Malformed polyline');
      value |= (byte & 31) << shift; shift += 5;
    } while (byte >= 32);
    return value & 1 ? ~(value >>> 1) : value >>> 1;
  };
  try {
    while (index < encoded.length) {
      lat += component(); lon += component();
      if (Math.abs(lat) > 9000000 || Math.abs(lon) > 18000000) return [];
      points.push([lon / 1e5, lat / 1e5]);
    }
    return points;
  } catch { return []; }
}
export function runningActivities(activities) {
  return activities.filter(a => ['Run', 'TrailRun', 'VirtualRun'].includes(a.sport_type))
    .map(({ id, name, distance, total_elevation_gain, moving_time, start_date, map }) => ({
      id, name, distance, total_elevation_gain, moving_time, start_date,
      coordinates: decodePolyline(map?.summary_polyline)
    })).sort((a, b) => Date.parse(b.start_date) - Date.parse(a.start_date));
}
export function targetForRun(runs, id, params) {
  const run = runs.find(run => String(run.id) === id);
  if (!run) return null;
  const result = new URLSearchParams(params);
  // Always derive the workout from this athlete's activity, not client-supplied metrics.
  result.set('distance', String(run.distance));
  result.set('ascent', String(run.total_elevation_gain));
  return { run, params: result };
}

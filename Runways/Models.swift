import Foundation
import CoreLocation

struct Run: Identifiable, Codable {
    let id: Int
    let name: String
    let distance: Double
    let total_elevation_gain: Double
    let moving_time: Double
    let start_date: String
    var coordinates: [[Double]]? = nil
    var km: Double { distance / 1000 }
    var points: [CLLocationCoordinate2D] { mapPoints(coordinates ?? []) }
    var pace: String {
        let seconds = Int(moving_time / max(km, 0.01))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var dateLabel: String {
        guard let date = ISO8601DateFormatter().date(from: start_date) else { return String(start_date.prefix(10)) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
struct Route: Identifiable, Codable {
    let id: String
    let name: String
    let distance: Double
    let ascent: Double
    let coordinates: [[Double]]
    var points: [CLLocationCoordinate2D] { mapPoints(coordinates) }
    func match(distance target: Double, ascent climb: Double) -> Int {
        let distanceError = 0.7 * abs(distance - target) / max(target, 1)
        let climbError = 0.3 * abs(ascent - climb) / max(climb, 30)
        return Int(max(0, 1 - distanceError - climbError) * 100)
    }
}
private func mapPoints(_ coordinates: [[Double]]) -> [CLLocationCoordinate2D] {
    coordinates.compactMap { point in
        guard point.count >= 2, point[0].isFinite, point[1].isFinite,
              abs(point[0]) <= 180, abs(point[1]) <= 90 else { return nil }
        return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
    }
}
struct RouteResponse: Decodable {
    let routes: [Route]
    let suggestions: [Route]?
    let message: String?
}
struct Session: Codable { let session: String }

// Illustrative geometry only; these are not real, navigable running routes.
private func demoLoop(_ variation: Int) -> [[Double]] {
    let shift = Double(variation) * 0.001
    return [
        [153.0251, -27.4698], [153.015 + shift, -27.462],
        [153.019, -27.451 - shift], [153.035 + shift, -27.453],
        [153.040, -27.465 + shift], [153.032, -27.475],
        [153.0251, -27.4698]
    ]
}
let demoRuns: [Run] = makeDemoRuns()
private func makeDemoRuns() -> [Run] {
    let names = ["Morning river loop", "Easy neighbourhood miles", "Hills before breakfast"]
    let formatter = ISO8601DateFormatter()
    var results: [Run] = []
    for i in 0..<12 {
        let variation = i % 4
        let distance = 6200.0 + Double(variation) * 1100.0
        let elevation = 45.0 + Double(variation) * 28.0
        let movingTime = 2200.0 + Double(variation) * 350.0
        let date = Date().addingTimeInterval(-Double(i) * 2.0 * 86400.0)
        let run = Run(id: i, name: names[i % 3], distance: distance,
                      total_elevation_gain: elevation, moving_time: movingTime,
                      start_date: formatter.string(from: date), coordinates: demoLoop(variation))
        results.append(run)
    }
    return results
}
func demoAlternatives(for run: Run) -> [Route] {
    var results: [Route] = []
    for i in 1...2 {
        let distance = run.distance * (i == 1 ? 1.02 : 0.96)
        let ascent = run.total_elevation_gain + Double(i * 4)
        let route = Route(id: "demo-\(run.id)-\(i)", name: "Example loop \(i)",
                          distance: distance, ascent: ascent, coordinates: demoLoop(i + 3))
        results.append(route)
    }
    return results
}

struct Account: Decodable {
    let athleteID: Int
    let writeAuthorized: Bool
    let routingConfigured: Bool
}
struct HistoryPage: Decodable {
    let runs: [Run]
    let nextBefore: Int?
}
struct NoteResult: Decodable {
    let updated: Bool
    let description: String
}
struct SavedRoute: Identifiable, Codable {
    let id: UUID
    let route: Route
    let discoveredAt: Date
    var completedRunID: Int?
    var noteAdded: Bool = false
}
enum RouteLibrary {
    static func load(athleteID: Int) -> [SavedRoute] {
        guard let data = UserDefaults.standard.data(forKey: "routes.\(athleteID)") else { return [] }
        return (try? JSONDecoder().decode([SavedRoute].self, from: data)) ?? []
    }
    static func save(_ routes: [SavedRoute], athleteID: Int) {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        UserDefaults.standard.set(data, forKey: "routes.\(athleteID)")
    }
    static func sameGeometry(_ a: Route, _ b: Route) -> Bool {
        a.coordinates == b.coordinates
    }
}
extension Run {
    var date: Date? { ISO8601DateFormatter().date(from: start_date) }
}
extension Route {
    func gpx() throws -> String {
        guard points.count >= 2 else {
            throw NSError(domain: "Runways", code: 2, userInfo: [NSLocalizedDescriptionKey: "This route has no exportable map."])
        }
        let escapedName = name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
        var track = ""
        for point in coordinates {
            guard point.count >= 2, point[0].isFinite, point[1].isFinite,
                  abs(point[0]) <= 180, abs(point[1]) <= 90 else { continue }
            let elevation = point.count >= 3 && point[2].isFinite ? "<ele>\(point[2])</ele>" : ""
            track += "<trkpt lat=\"\(point[1])\" lon=\"\(point[0])\">\(elevation)</trkpt>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Runways" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><name>\(escapedName)</name></metadata>
        <trk><name>\(escapedName)</name><trkseg>
        \(track)</trkseg></trk></gpx>
        """
    }
}

struct HeatCell: Identifiable {
    let id: String
    let latitude: Double
    let longitude: Double
    let count: Int
}
// Count distinct runs through a ~150 m grid, not GPS samples or time spent.
// Web Mercator gives a consistent grid; long gaps are skipped to respect hidden geometry.
func heatCells(for runs: [Run]) -> [HeatCell] {
    let earthRadius = 6_378_137.0
    let cellSize = 150.0
    var counts: [String: Int] = [:]
    var positions: [String: (Double, Double)] = [:]
    for run in runs {
        var visited: Set<String> = []
        var previous: (Double, Double)?
        for point in run.points {
            let latitude = min(85.0, max(-85.0, point.latitude)) * .pi / 180
            let x = earthRadius * point.longitude * .pi / 180
            let y = earthRadius * log(tan(.pi / 4 + latitude / 2))
            let start = previous ?? (x, y)
            let distance = hypot(x - start.0, y - start.1)
            let steps = distance < 2000 ? min(30, max(1, Int(distance / 75))) : 1
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                let sx = start.0 + (x - start.0) * fraction
                let sy = start.1 + (y - start.1) * fraction
                let gx = floor(sx / cellSize), gy = floor(sy / cellSize)
                let key = "\(Int(gx)):\(Int(gy))"
                visited.insert(key)
                positions[key] = ((gx + 0.5) * cellSize, (gy + 0.5) * cellSize)
            }
            previous = (x, y)
        }
        for key in visited { counts[key, default: 0] += 1 }
    }
    return counts.keys.sorted {
        let left = counts[$0, default: 0], right = counts[$1, default: 0]
        return left == right ? $0 < $1 : left > right
    }.prefix(5000).compactMap { key in
        guard let position = positions[key], let count = counts[key] else { return nil }
        let lon = position.0 / earthRadius * 180 / .pi
        let lat = (2 * atan(exp(position.1 / earthRadius)) - .pi / 2) * 180 / .pi
        return HeatCell(id: key, latitude: lat, longitude: lon, count: count)
    }
}

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
struct RouteResponse: Decodable { let routes: [Route] }
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

import Foundation
import CoreLocation

struct Run: Identifiable, Codable {
    let id: Int
    let name: String
    let distance: Double
    let total_elevation_gain: Double
    let moving_time: Double
    let start_date: String
    var km: Double { distance / 1000 }
    var pace: String {
        let seconds = Int(moving_time / max(km, 0.01))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
struct Route: Identifiable, Codable {
    let id: String
    let name: String
    let distance: Double
    let ascent: Double
    let coordinates: [[Double]]
    var points: [CLLocationCoordinate2D] {
        coordinates.filter { $0.count >= 2 }.map { .init(latitude: $0[1], longitude: $0[0]) }
    }
    func match(distance target: Double, ascent climb: Double) -> Int {
        let error = 0.7 * abs(distance - target) / max(target, 1) + 0.3 * abs(ascent - climb) / max(climb, 30)
        return Int(max(0, 1 - error) * 100)
    }
}
struct RouteResponse: Decodable { let routes: [Route] }
struct Session: Codable { let session: String }

let demoRuns: [Run] = (0..<12).map { i in
    Run(id: i, name: ["Morning river loop", "Easy neighbourhood miles", "Hills before breakfast"][i % 3], distance: Double(6200 + (i % 4) * 1100), total_elevation_gain: Double(45 + (i % 4) * 28), moving_time: Double(2200 + (i % 4) * 350), start_date: ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(-i * 2) * 86400)))
}

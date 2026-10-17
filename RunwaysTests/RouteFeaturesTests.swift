import XCTest
import Foundation
@testable import Runways

final class RouteFeaturesTests: XCTestCase {
    func testGPXEscapesNamePreservesCoordinatesAndSkipsInvalidPoints() throws {
        let route = Route(id: "test", name: "River & hills <loop>", distance: 1000, ascent: 20,
                          coordinates: [[153.0251, -27.4698, 12], [153.026, -27.468], [181, 0], [0, .infinity]])
        let text = try route.gpx()
        let reader = GPXReader()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = reader
        XCTAssertTrue(parser.parse())
        XCTAssertTrue(reader.names.contains("River & hills <loop>"))
        XCTAssertEqual(reader.points.count, 2)
        XCTAssertEqual(reader.points.first?["lat"], "-27.4698")
        XCTAssertEqual(reader.points.first?["lon"], "153.0251")
        XCTAssertTrue(text.contains("<ele>12.0</ele>"))
        XCTAssertFalse(text.contains("<time>"), "A planned route must not pretend to be a recorded activity")
    }
    func testUnmappedRouteCannotBeExported() {
        let route = Route(id: "empty", name: "Private", distance: 1000, ascent: 0, coordinates: [])
        XCTAssertThrowsError(try route.gpx())
    }
    func testHeatCountsRunsRatherThanRepeatedGPSSamples() {
        let points = Array(repeating: [153.0251, -27.4698], count: 100)
        let first = run(id: 1, points: points)
        let second = run(id: 2, points: points)
        XCTAssertEqual(heatCells(for: [first]).first?.count, 1)
        XCTAssertEqual(heatCells(for: [first, second]).first?.count, 2)
        XCTAssertEqual(heatCells(for: [run(id: 3, points: [])]).count, 0)
    }
    func testHeatDoesNotFillLongPrivateGeometryGaps() {
        let cells = heatCells(for: [run(id: 1, points: [[0, 0], [1, 1]])])
        XCTAssertEqual(cells.count, 2)
    }
    func testRouteLibraryIsSeparatedByStravaAthleteAndSurvivesReload() {
        let athleteA = -900001, athleteB = -900002
        defer {
            UserDefaults.standard.removeObject(forKey: "routes.\(athleteA)")
            UserDefaults.standard.removeObject(forKey: "routes.\(athleteB)")
        }
        let route = Route(id: "11-0", name: "Loop", distance: 8000, ascent: 100,
                          coordinates: [[153, -27], [153.01, -27.01]])
        let saved = SavedRoute(id: UUID(), route: route, discoveredAt: Date(), completedRunID: 42)
        RouteLibrary.save([saved], athleteID: athleteA)
        RouteLibrary.save([], athleteID: athleteB)
        XCTAssertEqual(RouteLibrary.load(athleteID: athleteA).first?.completedRunID, 42)
        XCTAssertEqual(RouteLibrary.load(athleteID: athleteB).count, 0)
        let different = Route(id: "11-0", name: "Different loop", distance: 8000, ascent: 100,
                              coordinates: [[154, -27], [154.01, -27.01]])
        XCTAssertFalse(RouteLibrary.sameGeometry(route, different), "Provider seed IDs must not merge different routes")
    }
    private func run(id: Int, points: [[Double]]) -> Run {
        Run(id: id, name: "Test", distance: 1000, total_elevation_gain: 0,
            moving_time: 300, start_date: "2026-10-17T00:00:00Z", coordinates: points)
    }
}
private final class GPXReader: NSObject, XMLParserDelegate {
    var points: [[String: String]] = []
    var names: [String] = []
    private var currentName: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "trkpt" { points.append(attributeDict) }
        if elementName == "name" { currentName = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentName != nil { currentName?.append(string) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "name", let value = currentName { names.append(value); currentName = nil }
    }
}

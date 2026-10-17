import SwiftUI
import MapKit
import Charts
import AuthenticationServices
import UniformTypeIdentifiers

@main struct RunwaysApp: App {
    var body: some Scene { WindowGroup { Dashboard() } }
}

@MainActor
struct Dashboard: View {
    private let backend = "https://runways.onrender.com"
    @State private var token = SessionStore.read() ?? ""
    @State private var runs: [Run] = SessionStore.read() == nil ? demoRuns : []
    @State private var routes: [Route] = []
    @State private var selected: Route?
    @State private var target = 8.0
    @State private var climb = 100.0
    @AppStorage("homeRadius") private var radius = 5.0
    @State private var home = CLLocationCoordinate2D(latitude: -27.4698, longitude: 153.0251)
    @State private var camera: MapCameraPosition = .region(.init(center: .init(latitude: -27.4698, longitude: 153.0251), span: .init(latitudeDelta: 0.09, longitudeDelta: 0.09)))
    @State private var pickingHome = false
    @State private var busy = false
    @State private var message: String?
    @State private var auth: ASWebAuthenticationSession?
    private let accent = Color(red: 0.77, green: 0.96, blue: 0.36)
    private var api: API? {
        guard let url = URL(string: backend), url.scheme == "https", url.host != nil else { return nil }
        return API(base: url, token: token)
    }
    private var sorted: [Route] { routes.sorted { $0.match(distance: target * 1000, ascent: climb) > $1.match(distance: target * 1000, ascent: climb) } }
    @State private var activeTab = 0
    @State private var alternatives: [Int: [Route]] = [:]
    @State private var alternativeErrors: [Int: String] = [:]
    @State private var closestOptions: [Int: [Route]] = [:]
    @State private var showingClosest: Set<Int> = []
    @State private var loadingAlternatives: Set<Int> = []
    @State private var detail: Route?
    @State private var detailClimbingTarget: Double?
    @State private var showingDemo: Bool = SessionStore.read() == nil
    @State private var syncing = false
    @State private var feedVersion = UUID()
    @State private var account: Account?
    @State private var savedRoutes: [SavedRoute] = []
    @State private var olderRuns: [Run] = []
    @State private var density: [HeatCell] = []
    @State private var loadingHistory = false
    @State private var historyFinished = false
    @State private var historyBefore: Int?
    @State private var historyMessage: String?
    @State private var showHistory = true
    @State private var showDiscoveries = true
    @State private var heatCamera: MapCameraPosition = .automatic
    private var allHeatRuns: [Run] {
        var seen: Set<Int> = []
        return (runs + olderRuns).filter { seen.insert($0.id).inserted }
    }
    private var hasHome: Bool { UserDefaults.standard.object(forKey: "homeLat") != nil }
    private var feedContext: String {
        "\(feedVersion)-\(token)-\(home.latitude)-\(home.longitude)-\(radius)"
    }
    var body: some View {
        TabView(selection: $activeTab) {
            NavigationStack {
                homeFeed
                    .navigationTitle("RUNWAYS")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("A different way home.").font(.largeTitle.bold()).foregroundStyle(accent)
                        planner
                    }.padding(24)
                }
                .background(Color(red: 0.055, green: 0.075, blue: 0.065))
                .navigationTitle("Plan a run")
                .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }.tag(1)
            NavigationStack { heatMap }
                .tabItem { Label("Heat map", systemImage: "map.fill") }.tag(2)
            NavigationStack { settingsView }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
        }
        .onChange(of: radius) { _, _ in resetFeedMatches(); routes = []; selected = nil }
        .preferredColorScheme(.dark).tint(accent)
        .sheet(item: $detail, onDismiss: { detailClimbingTarget = nil }) { route in
            RouteDetails(
                route: route, isDemo: showingDemo, effortWarning: detailClimbingTarget.map { String(format: "Closest option: %.0f m climbing versus your %.0f m target. This route is outside the elevation match tolerance.", route.ascent, $0) }, runs: showingDemo ? [] : allHeatRuns,
                saved: savedRoutes.first(where: { RouteLibrary.sameGeometry($0.route, route) }),
                canWrite: account?.writeAuthorized == true,
                onSave: { remember([route]) },
                onLink: { runID in link(route, to: runID) },
                onSettings: { detail = nil; activeTab = 3 },
                onNote: { runID in try await addNote(route, runID: runID) }
            )
        }
        .task {
            if hasHome {
                home = .init(latitude: UserDefaults.standard.double(forKey: "homeLat"), longitude: UserDefaults.standard.double(forKey: "homeLon"))
                camera = .region(.init(center: home, span: .init(latitudeDelta: 0.09, longitudeDelta: 0.09)))
            }
            rebuildHeat()
            if !token.isEmpty { await sync() }
        }
    }
    private var homeFeed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your running, lately.").font(.largeTitle.bold())
                    Text("Same effort. New surroundings.").foregroundStyle(accent)
                }
                Text(showingDemo ? "DEMO DATA · Example runs and illustrative maps" : "YOUR STRAVA TRAINING")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                if syncing { ProgressView("Refreshing runs…") }
                trend
                HStack {
                    Text("Recent runs").font(.title2.bold())
                    Spacer()
                    Button(showingDemo ? "Connect" : "Refresh") {
                        if showingDemo { activeTab = 3 } else { Task { await sync() } }
                    }.disabled(syncing)
                }
                if !showingDemo {
                    Button { activeTab = 3 } label: {
                        Label(hasHome ? String(format: "Alternatives within %.1f km of home · Edit", radius) : "Set home in Settings to find matched alternatives", systemImage: "house")
                            .font(.caption)
                    }
                }
                Text("Alternatives are searched near your saved home, not the original run’s starting point.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.callout).foregroundStyle(.orange) }
                if runs.isEmpty {
                    Text(token.isEmpty ? "Connect Strava to see your runs." : "No runs loaded. Refresh to try again.")
                        .foregroundStyle(.secondary).padding(.vertical)
                }
                ForEach(runs) { run in
                    feedCard(run)
                        .task(id: feedContext) { await loadAlternatives(for: run, context: feedContext) }
                }
                Text("Matches compare distance (70%) and climbing (30%). Terrain and conditions affect effort. Always review a route before running.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.065))
        .refreshable { if !token.isEmpty { await sync() } }
    }
    private func feedCard(_ run: Run) -> some View {
        let isClosest = showingClosest.contains(run.id) && !showingDemo
        let matches = showingDemo ? demoAlternatives(for: run) : (isClosest ? closestOptions[run.id] ?? [] : alternatives[run.id] ?? [])
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "figure.run").foregroundStyle(accent).padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.name).font(.headline)
                    Text(run.dateLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            RunMap(points: run.points, tint: accent, emptyText: "No route map shared for this run")
                .frame(height: 190)
            HStack {
                runStat("DISTANCE", String(format: "%.1f km", run.km))
                Spacer()
                runStat("ELEVATION", String(format: "%.0f m", run.total_elevation_gain))
                Spacer()
                runStat("PACE", "\(run.pace) /km")
            }
            Divider().overlay(.white.opacity(0.1))
            HStack {
                Text(showingDemo ? "EXAMPLE ALTERNATIVES" : (isClosest ? "CLOSEST OPTIONS · ELEVATION DIFFERS" : "MATCHED ALTERNATIVES"))
                    .font(.caption2.bold()).tracking(1)
                Spacer()
                if loadingAlternatives.contains(run.id) { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<2, id: \.self) { index in
                    if index < matches.count {
                        alternativeTile(matches[index], run: run, isClosest: isClosest)
                    } else {
                        alternativePlaceholder(run, index: index, count: matches.count)
                    }
                }
            }
            if let options = closestOptions[run.id], !options.isEmpty, !showingDemo {
                Button(isClosest ? "Hide closest options" : "Show closest options · climbing differs") {
                    if isClosest { showingClosest.remove(run.id) }
                    else { showingClosest.insert(run.id) }
                }.font(.caption.bold())
            }
            if let error = alternativeErrors[run.id], !showingDemo {
                Text(error).font(.caption).foregroundStyle(.secondary)
                if hasHome && !loadingAlternatives.contains(run.id) {
                    Button("Retry alternatives") {
                        alternativeErrors[run.id] = nil
                        alternatives[run.id] = nil
                        closestOptions[run.id] = nil
                        showingClosest.remove(run.id)
                        Task { await loadAlternatives(for: run, context: feedContext) }
                    }.font(.caption)
                }
            }
            Button("Use this effort in Plan") {
                target = min(30, max(2, run.km))
                climb = min(800, max(0, run.total_elevation_gain))
                routes = []; selected = nil; activeTab = 1
            }.font(.caption.bold())
        }
        .padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
    }
    private func runStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).monospacedDigit()
        }
    }
    private func alternativeTile(_ route: Route, run: Run, isClosest: Bool) -> some View {
        Button { detailClimbingTarget = isClosest ? run.total_elevation_gain : nil; detail = route } label: {
            VStack(alignment: .leading, spacing: 7) {
                RunMap(points: route.points, tint: accent, emptyText: "Map unavailable").frame(height: 105)
                Text(route.name).font(.caption.bold()).lineLimit(1)
                Text(String(format: "%.1f km · %.0f m ↑", route.distance / 1000, route.ascent))
                    .font(.caption2).foregroundStyle(.secondary)
                if isClosest {
                    Text(String(format: "%+.0f m climbing vs run", route.ascent - run.total_elevation_gain))
                        .font(.caption2.bold()).foregroundStyle(.orange)
                } else {
                    Text("\(route.match(distance: run.distance, ascent: run.total_elevation_gain))% similar")
                        .font(.caption.bold()).foregroundStyle(accent)
                }
                Label("View route", systemImage: "arrow.up.right").font(.caption.bold()).foregroundStyle(accent)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("View \(route.name), \(String(format: "%.1f", route.distance / 1000)) kilometres, \(Int(route.ascent)) metres climbing")
            .accessibilityHint("Opens the route map, GPX export and sharing")
    }
    private func alternativePlaceholder(_ run: Run, index: Int, count: Int) -> some View {
        let text: String
        if showingDemo { text = "Example map" }
        else if !hasHome { text = "Set home in Settings" }
        else if account?.routingConfigured == false { text = "Discovery unavailable" }
        else if loadingAlternatives.contains(run.id) { text = "Finding a match…" }
        else if count > 0 { text = "No second match found" }
        else { text = "No match available" }
        return VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.04))
                .frame(height: 105)
                .overlay {
                    VStack(spacing: 7) {
                        Image(systemName: "map").font(.title3)
                        Text(text).font(.caption2).multilineTextAlignment(.center)
                    }.foregroundStyle(.secondary).padding(8)
                }
            Text("Alternative \(index + 1)").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func loadAlternatives(for run: Run, context: String) async {
        guard !showingDemo, !token.isEmpty, hasHome, account?.routingConfigured == true, let api,
              alternatives[run.id] == nil, alternativeErrors[run.id] == nil,
              !loadingAlternatives.contains(run.id) else { return }
        guard (2000...30000).contains(run.distance), (0...800).contains(run.total_elevation_gain) else {
            alternativeErrors[run.id] = "Automatic matches currently support runs from 2–30 km with up to 800 m climbing."
            return
        }
        loadingAlternatives.insert(run.id)
        defer { if context == feedContext { loadingAlternatives.remove(run.id) } }
        do {
            let values = ["lat": home.latitude, "lon": home.longitude, "radius": radius * 1000]
            let query = values.map { URLQueryItem(name: $0.key, value: String($0.value)) }
            let result: RouteResponse = try await api.get("runs/\(run.id)/alternatives", query: query)
            guard context == feedContext, !Task.isCancelled else { return }
            alternatives[run.id] = Array(result.routes.prefix(2))
            closestOptions[run.id] = Array((result.suggestions ?? []).prefix(2))
            remember(result.routes)
            if let explanation = result.message { alternativeErrors[run.id] = explanation }
            else if result.routes.isEmpty { alternativeErrors[run.id] = "No similar loops found in your home radius. Try changing it in Settings." }
        } catch {
            guard context == feedContext else { return }
            if Task.isCancelled { return }
            alternativeErrors[run.id] = error.localizedDescription
        }
    }
    private func resetFeedMatches() {
        alternatives = [:]; alternativeErrors = [:]; loadingAlternatives = []; closestOptions = [:]; showingClosest = []
        feedVersion = UUID()
    }
    private var planner: some View {
        VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Plan your next run").font(.title2.bold())
                        Text("Match a planned workout, then explore a new loop.").font(.subheadline).foregroundStyle(.secondary)
                        slider("Distance", value: $target, range: 2...30, suffix: "km")
                        slider("Elevation gain", value: $climb, range: 0...800, suffix: "m")
                        Button { activeTab = 3 } label: {
                            Label(hasHome ? String(format: "Within %.1f km of home · Edit in Settings", radius) : "Choose home in Settings", systemImage: "house")
                        }
                        RunMap(points: selected?.points ?? [], tint: accent, emptyText: "Your matched route will appear here")
                            .frame(height: 230)
                        if account?.routingConfigured == false && !showingDemo {
                            Text("Route discovery is not available yet. Your Strava history and heat map still work.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button { Task { await findRoutes() } } label: {
                            HStack { Spacer(); if busy { ProgressView().tint(.black) }; Text(busy ? "Finding your loops…" : "Find a different route").bold(); Image(systemName: "arrow.up.right"); Spacer() }.padding()
                        }.background(accent, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.black).disabled(busy)
                    }.padding(20).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
                    if let message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if !routes.isEmpty {
                        Text("Your alternative loops").font(.title2.bold())
                        Text("Similarity uses distance (70%) and climbing (30%). Surface, heat and technical terrain also affect effort. Review access and safety before running.").font(.caption).foregroundStyle(.secondary)
                        ForEach(sorted) { route in
                            Button { selected = route; detail = route } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 8) { Text(route.name).font(.headline); Text(String(format: "%.1f km  ·  %.0f m climb", route.distance / 1000, route.ascent)).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text("\(route.match(distance: target * 1000, ascent: climb))%\nsimilar").font(.subheadline.bold()).foregroundStyle(accent)
                                }.padding(20).background(.white.opacity(selected?.id == route.id ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain)
                        }
                    }
        }
        .onChange(of: target) { _, _ in routes = []; selected = nil }
        .onChange(of: climb) { _, _ in routes = []; selected = nil }
    }
    private var trend: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent distance trend").font(.headline)
            Chart(runs.reversed()) { run in
                if let date = run.date {
                    BarMark(x: .value("Date", date, unit: .day), y: .value("Distance (km)", run.km))
                        .foregroundStyle(accent.gradient).cornerRadius(4)
                }
            }
            .frame(height: 155)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartXAxisLabel("Run date")
            .chartYAxisLabel("km")
            Text(String(format: "%.1f km across %d runs · %.0f m total climbing", runs.reduce(0) { $0 + $1.km }, runs.count, runs.reduce(0) { $0 + $1.total_elevation_gain })).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack { HStack { Text(title); Spacer(); Text(String(format: suffix == "m" ? "%.0f %@" : "%.1f %@", value.wrappedValue, suffix)).monospacedDigit().bold() }; Slider(value: value, in: range) }
    }
    private var settingsView: some View {
        Form {
            Section("Strava") {
                Text(token.isEmpty ? "Not connected" : "Connected")
                    .foregroundStyle(token.isEmpty ? Color.secondary : accent)
                Button(token.isEmpty ? "Connect Strava" : "Reconnect Strava") { connect() }
                if !token.isEmpty {
                    Button("Refresh runs") { Task { await sync() } }.disabled(syncing)
                    Button("Disconnect", role: .destructive) { Task { await disconnect() } }
                }
            }
            Section("Activity notes") {
                Text("Optionally add ‘Explored a new loop with Runways.’ to a completed run’s Strava description. Existing text is kept. Nothing is posted without confirmation.").font(.caption)
                if account?.writeAuthorized == true {
                    Label("Activity notes enabled", systemImage: "checkmark.circle")
                } else {
                    Button("Enable Strava activity notes") { connect(write: true) }
                }
                Text("After running a discovered route, open it from Heat map, link your completed Strava run, then choose Add note. Runways does not record or upload activities yet.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Home & route radius") {
                        slider("Home radius", value: $radius, range: 1...20, suffix: "km")
                        Button { pickingHome.toggle() } label: { Label(pickingHome ? "Tap the map to place home" : "Choose home on map", systemImage: "house") }
                        Text("The initial map is an example location in Brisbane. Set your home before searching. When connected and route discovery is available, Home searches automatically inside this radius. The routing provider then receives the start point.").font(.caption).foregroundStyle(.secondary)
                        MapReader { proxy in
                            Map(position: $camera) {
                                Annotation("Home", coordinate: home) { Image(systemName: "house.fill").padding(10).background(accent, in: Circle()).foregroundStyle(.black) }
                                MapCircle(center: home, radius: radius * 1000).foregroundStyle(accent.opacity(0.08))
                                if let selected { MapPolyline(coordinates: selected.points).stroke(accent, lineWidth: 5) }
                            }
                            .onTapGesture { point in
                                if pickingHome, let coordinate = proxy.convert(point, from: .local) {
                                    home = coordinate; routes = []; selected = nil; pickingHome = false
                                    UserDefaults.standard.set(home.latitude, forKey: "homeLat")
                                    UserDefaults.standard.set(home.longitude, forKey: "homeLon")
                                    resetFeedMatches()
                                }
                            }
                        }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 20))

            }
            Section("Route discovery") {
                Text(account?.routingConfigured == true ? "Available" : "Not available yet")
                Text("Strava supplies your run history. A separate routing service supplies new loops. History, sharing saved routes and the heat map work independently.").font(.caption).foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).foregroundStyle(.orange) } }
        }.navigationTitle("Settings")
    }
    private var heatMap: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Where you’ve been. Where’s next.").font(.title2.bold())
                if showingDemo { Text("DEMO · Illustrative run geometry").font(.caption).foregroundStyle(.secondary) }
                Toggle("Completed Strava runs", isOn: $showHistory)
                Toggle("Saved discoveries", isOn: $showDiscoveries)
                heatCanvas
                HStack {
                    Label("Fewer runs", systemImage: "circle.fill").foregroundStyle(.yellow)
                    Spacer()
                    Label("More runs", systemImage: "circle.fill").foregroundStyle(.red)
                }.font(.caption)
                Text("Density counts distinct completed runs through approximate 150 m cells. Dashed green lines are discovered routes, not proof they were run. Map-hidden activities cannot contribute. Up to 5,000 highest-use cells are displayed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(allHeatRuns.count) runs loaded · \(savedRoutes.count) saved discoveries")
                    .font(.caption.bold())
                if !showingDemo {
                    Button { Task { await loadOlderHistory() } } label: {
                        if loadingHistory { ProgressView("Loading older runs…") }
                        else { Text(historyFinished ? "All available history loaded" : "Load older Strava history") }
                    }.disabled(loadingHistory || historyFinished)
                }
                if let historyMessage { Text(historyMessage).font(.caption).foregroundStyle(.secondary) }
                if density.isEmpty { Text("No mapped runs loaded. Connect Strava or load older history to build your heat map.").foregroundStyle(.secondary) }
                Text("Discovered routes").font(.title2.bold())
                if savedRoutes.isEmpty { Text("New routes appear here when you find alternatives in Home or Plan.").foregroundStyle(.secondary) }
                ForEach(savedRoutes) { saved in
                    HStack {
                        Button { detail = saved.route } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(saved.route.name).bold()
                                Text(String(format: "%.1f km · %.0f m ↑", saved.route.distance / 1000, saved.route.ascent)).font(.caption)
                                if saved.completedRunID != nil { Text("Linked to a completed Strava run").font(.caption2).foregroundStyle(accent) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button(role: .destructive) {
                            savedRoutes.removeAll { $0.id == saved.id }; persistLibrary()
                        } label: { Image(systemName: "trash") }.accessibilityLabel("Remove saved route")
                    }.padding().background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                }
            }.padding(24)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.065))
        .navigationTitle("Heat map").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Fit map") { heatCamera = .automatic } }
    }
    private var heatCanvas: some View {
        Map(position: $heatCamera) {
                    if showHistory {
                        ForEach(density) { cell in
                            MapCircle(center: CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude), radius: 95)
                                .foregroundStyle(heatColor(cell.count).opacity(0.55))
                        }
                    }
                    if showDiscoveries {
                        ForEach(savedRoutes) { saved in
                            MapPolyline(coordinates: saved.route.points)
                                .stroke(accent, style: StrokeStyle(lineWidth: 3, dash: [5, 4]))
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .frame(height: 390).clipShape(RoundedRectangle(cornerRadius: 20))
    }
    private func heatColor(_ count: Int) -> Color {
        if count >= 5 { return .red }
        if count >= 2 { return .orange }
        return .yellow
    }
    private func rebuildHeat() {
        density = heatCells(for: allHeatRuns)
        heatCamera = .automatic
    }
    private func remember(_ discovered: [Route]) {
        guard !showingDemo, account != nil else { return }
        for route in discovered where route.points.count >= 2 {
            if !savedRoutes.contains(where: { RouteLibrary.sameGeometry($0.route, route) }) {
                savedRoutes.insert(SavedRoute(id: UUID(), route: route, discoveredAt: Date()), at: 0)
            }
        }
        persistLibrary()
    }
    private func persistLibrary() {
        guard let account else { return }
        RouteLibrary.save(savedRoutes, athleteID: account.athleteID)
    }
    private func link(_ route: Route, to runID: Int) {
        remember([route])
        guard let index = savedRoutes.firstIndex(where: { RouteLibrary.sameGeometry($0.route, route) }) else { return }
        savedRoutes[index].completedRunID = runID
        savedRoutes[index].noteAdded = false
        persistLibrary()
    }
    private func addNote(_ route: Route, runID: Int) async throws {
        guard let api, let current = account, !token.isEmpty else {
            throw NSError(domain: "Runways", code: 3, userInfo: [NSLocalizedDescriptionKey: "Reconnect Strava before adding a note."])
        }
        let result: NoteResult = try await api.post("runs/\(runID)/note")
        guard current.athleteID == account?.athleteID else {
            throw NSError(domain: "Runways", code: 3, userInfo: [NSLocalizedDescriptionKey: "The connected Strava account changed. Please refresh."])
        }
        if let index = savedRoutes.firstIndex(where: { RouteLibrary.sameGeometry($0.route, route) }) {
            savedRoutes[index].noteAdded = !result.description.isEmpty
            persistLibrary()
        }
    }
    private func loadOlderHistory() async {
        guard let api, !token.isEmpty, !loadingHistory, !showingDemo else { return }
        let requestedToken = token
        let fallback = runs.compactMap(\.date).min() ?? Date()
        let before = historyBefore ?? Int(fallback.timeIntervalSince1970)
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            let page: HistoryPage = try await api.get("history", query: [URLQueryItem(name: "before", value: String(before))])
            guard token == requestedToken else { return }
            let existing = Set(allHeatRuns.map(\.id))
            olderRuns.append(contentsOf: page.runs.filter { !existing.contains($0.id) })
            historyFinished = page.nextBefore == nil || (page.nextBefore ?? before) >= before
            historyBefore = page.nextBefore
            historyMessage = page.runs.isEmpty && !historyFinished ? "No runs in this batch of activities. Load another batch to look further back." : nil
            rebuildHeat()
        } catch { historyMessage = error.localizedDescription }
    }
    private func connect(write: Bool = false) {
        guard let api else { message = "Enter a valid HTTPS backend URL."; return }
        var authorization = URLComponents(url: api.base.appendingPathComponent("auth/strava"), resolvingAgainstBaseURL: false)!
        authorization.queryItems = write ? [URLQueryItem(name: "write", value: "1")] : []
        let session = ASWebAuthenticationSession(url: authorization.url!, callbackURLScheme: "runways") { url, error in
            Task { @MainActor in
                guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let ticket = parts.queryItems?.first(where: { $0.name == "ticket" })?.value else {
                    message = error?.localizedDescription ?? "Strava connection was not completed."; return
                }
                do {
                    let result: Session = try await api.get("auth/exchange", query: [.init(name: "ticket", value: ticket)])
                    token = result.session; SessionStore.save(token)
                    showingDemo = false; runs = []; account = nil; savedRoutes = []; olderRuns = []; rebuildHeat(); resetFeedMatches(); await sync()
                } catch { message = error.localizedDescription }
            }
        }
        session.presentationContextProvider = AuthWindow.shared
        session.prefersEphemeralWebBrowserSession = true
        auth = session
        if !session.start() { message = "Unable to open Strava authentication." }
    }
    private func sync() async {
        guard let api else { return }
        guard !syncing else { return }
        syncing = true
        let requestedToken = token
        let requestedBackend = backend
        defer { syncing = false }
        do {
            let currentAccount: Account = try await api.get("account")
            let result: [Run] = try await api.get("runs")
            guard token == requestedToken, backend == requestedBackend else { return }
            if account?.athleteID != currentAccount.athleteID {
                savedRoutes = RouteLibrary.load(athleteID: currentAccount.athleteID)
                olderRuns = []; historyBefore = nil; historyFinished = false
            }
            account = currentAccount
            runs = result; showingDemo = false; resetFeedMatches(); rebuildHeat()
            message = result.isEmpty ? "No runs found in the latest 100 activities." : nil
        }
        catch { message = error.localizedDescription }
    }
    private func disconnect() async {
        guard let api else { return }
        do { let _: Session = try await api.get("disconnect"); token = ""; SessionStore.save(nil); runs = demoRuns; showingDemo = true; account = nil; savedRoutes = []; olderRuns = []; historyBefore = nil; historyFinished = false; resetFeedMatches(); rebuildHeat(); message = nil }
        catch { message = error.localizedDescription }
    }
    private func findRoutes() async {
        guard hasHome else { message = "Choose your home in Settings before finding routes."; return }
        guard let api, !token.isEmpty else { message = "Connect Strava in Connections to generate live routes. Demo history is for exploring the interface."; return }
        busy = true; message = nil
        let requestedContext = feedContext
        let requestedTarget = target
        let requestedClimb = climb
        defer { busy = false }
        do {
            let response: RouteResponse = try await api.get("routes", query: ["lat": home.latitude, "lon": home.longitude, "distance": target * 1000, "ascent": climb, "radius": radius * 1000].map { .init(name: $0.key, value: String($0.value)) })
            guard feedContext == requestedContext, target == requestedTarget, climb == requestedClimb else { return }
            routes = response.routes; remember(response.routes); selected = sorted.first
            if routes.isEmpty { message = "No matching loops fit this radius. Increase the radius or adjust the distance and climbing." }
        } catch { message = error.localizedDescription }
    }
}
struct GPXDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "gpx") ?? .xml] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        text = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

@MainActor
struct RouteDetails: View {
    let route: Route
    let isDemo: Bool
    let effortWarning: String?
    let runs: [Run]
    let saved: SavedRoute?
    let canWrite: Bool
    let onSave: () -> Void
    let onLink: (Int) -> Void
    let onSettings: () -> Void
    let onNote: (Int) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var document = GPXDocument(text: "")
    @State private var exporting = false
    @State private var confirmingNote = false
    @State private var linkedRunID: Int?
    @State private var noteAdded = false
    @State private var postingNote = false
    @State private var status: String?
    private let accent = Color(red: 0.77, green: 0.96, blue: 0.36)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    RunMap(points: route.points, tint: accent, emptyText: "Route map unavailable").frame(height: 300)
                    Text(String(format: "%.1f km · %.0f m climb", route.distance / 1000, route.ascent)).font(.headline)
                    if let effortWarning { Text(effortWarning).font(.callout.bold()).foregroundStyle(.orange) }
                    if isDemo {
                        Text("Illustrative demo route. Export and navigation are available for real discovered routes after connection.")
                            .foregroundStyle(.secondary)
                    } else {
                        exportActions
                        completionActions
                    }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("Check surface, access and safety before running. Share only routes and location details you are comfortable making public.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
            .navigationTitle(route.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .preferredColorScheme(.dark).tint(accent)
        .task {
            linkedRunID = saved?.completedRunID
            noteAdded = saved?.noteAdded ?? false
            guard !isDemo else { return }
            do {
                let text = try route.gpx()
                document = GPXDocument(text: text)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RunwaysExports", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let previous = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for old in previous {
                    let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    if let date, date < Date().addingTimeInterval(-86400) { try? FileManager.default.removeItem(at: old) }
                }
                let url = directory.appendingPathComponent("Runways-\(UUID().uuidString).gpx")
                try Data(text.utf8).write(to: url, options: .atomic)
                fileURL = url
            } catch { status = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: document,
                      contentType: UTType(filenameExtension: "gpx") ?? .xml,
                      defaultFilename: "Runways-route") { result in
            if case .failure(let error) = result { status = error.localizedDescription }
        }
        .alert("Add a note on Strava?", isPresented: $confirmingNote) {
            Button("Cancel", role: .cancel) { }
            Button("Add note") { Task { await postNote() } }
        } message: {
            Text("Add ‘Explored a new loop with Runways.’ to the selected completed run’s description? Existing text will be kept. This changes that Strava activity, not its comments.")
        }
    }
    private var exportActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let fileURL {
                ShareLink(item: fileURL, subject: Text(route.name), message: Text("A running route to explore.")) {
                    Label("Share route", systemImage: "square.and.arrow.up")
                }
                Button { exporting = true } label: { Label("Save GPX to Files", systemImage: "square.and.arrow.down") }
            }
            Button { openStart() } label: { Label("Directions to start in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond") }
                .disabled(route.points.isEmpty)
            Text("Share the GPX with an app or device that supports route imports. Apple Maps calculates its own directions to the starting point; it won’t follow the full GPX loop. Strava route import may require its website and account features.")
                .font(.caption).foregroundStyle(.secondary)
            if saved == nil { Button("Save to heat map") { onSave(); status = "Route saved to your discoveries." } }
        }
    }
    private var completionActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text("Ran this route?").font(.title3.bold())
            Text("Record the run with Strava or your watch, refresh Home, then select the completed activity below. Linking does not upload a new activity or verify GPS matching.")
                .font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(runs) { run in
                    Button("\(run.name) · \(run.dateLabel)") {
                        linkedRunID = run.id; noteAdded = false
                        onLink(run.id); status = "Linked to \(run.name)."
                    }
                }
            } label: {
                Label(linkedRunID == nil ? "Link completed Strava run" : "Change linked Strava run", systemImage: "link")
            }.disabled(runs.isEmpty || postingNote)
            if let id = linkedRunID {
                Text(runs.first(where: { $0.id == id })?.name ?? "Strava activity \(id)")
                    .font(.caption.bold())
                if canWrite {
                    Button {
                        confirmingNote = true
                    } label: {
                        if postingNote { ProgressView("Adding note…") }
                        else { Label(noteAdded ? "Note added to Strava" : "Add optional note on Strava", systemImage: "text.bubble") }
                    }.disabled(postingNote || noteAdded)
                } else {
                    Button("Enable activity notes in Settings") { onSettings() }
                }
            }
        }
    }
    private func openStart() {
        guard let start = route.points.first else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: start))
        item.name = "\(route.name) start"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
    @MainActor private func postNote() async {
        guard let id = linkedRunID else { return }
        postingNote = true
        defer { postingNote = false }
        do {
            try await onNote(id)
            noteAdded = true; status = "Note added to your Strava description."
        } catch { status = error.localizedDescription }
    }
}

struct RunMap: View {
    let points: [CLLocationCoordinate2D]
    let tint: Color
    let emptyText: String
    var body: some View {
        Group {
            if points.count >= 2 {
                Map(initialPosition: .automatic, interactionModes: []) {
                    MapPolyline(coordinates: points).stroke(tint, lineWidth: 4)
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .allowsHitTesting(false)
                .accessibilityLabel("Run route map")
            } else {
                Rectangle().fill(.white.opacity(0.04))
                    .overlay {
                        Label(emptyText, systemImage: "map")
                            .font(.caption).foregroundStyle(.secondary).padding()
                    }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
final class AuthWindow: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthWindow()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

import SwiftUI
import MapKit
import Charts
import AuthenticationServices

@main struct RunwaysApp: App {
    var body: some Scene { WindowGroup { Dashboard() } }
}

@MainActor
struct Dashboard: View {
    @AppStorage("backend") private var backend = "https://your-backend.example.com"
    @State private var token = SessionStore.read() ?? ""
    @State private var runs: [Run] = SessionStore.read() == nil ? demoRuns : []
    @State private var routes: [Route] = []
    @State private var selected: Route?
    @State private var target = 8.0
    @State private var climb = 100.0
    @State private var radius = 5.0
    @State private var home = CLLocationCoordinate2D(latitude: -27.4698, longitude: 153.0251)
    @State private var camera: MapCameraPosition = .region(.init(center: .init(latitude: -27.4698, longitude: 153.0251), span: .init(latitudeDelta: 0.09, longitudeDelta: 0.09)))
    @State private var pickingHome = false
    @State private var settings = false
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
    @State private var loadingAlternatives: Set<Int> = []
    @State private var detail: Route?
    @State private var showingDemo: Bool = SessionStore.read() == nil
    @State private var syncing = false
    @State private var feedVersion = UUID()
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
                    .toolbar { Button { settings = true } label: { Image(systemName: "slider.horizontal.3") } }
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
                .toolbar { Button { settings = true } label: { Image(systemName: "slider.horizontal.3") } }
            }
            .tabItem { Label("Plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }.tag(1)
        }
        .preferredColorScheme(.dark).tint(accent)
        .sheet(isPresented: $settings) { settingsView }
        .sheet(item: $detail) { route in
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    RunMap(points: route.points, tint: accent, emptyText: "Route map unavailable")
                    Text(String(format: "%.1f km · %.0f m climb", route.distance / 1000, route.ascent)).font(.headline)
                    Text(showingDemo ? "Illustrative demo route, not a navigable path." : "Review surface, access and safety before running. Similarity estimates distance and climbing, not physiological effort.").font(.caption).foregroundStyle(.secondary)
                }.padding().navigationTitle(route.name)
                    .toolbar { Button("Done") { detail = nil } }
            }.preferredColorScheme(.dark)
        }
        .task {
            if hasHome {
                home = .init(latitude: UserDefaults.standard.double(forKey: "homeLat"), longitude: UserDefaults.standard.double(forKey: "homeLon"))
                camera = .region(.init(center: home, span: .init(latitudeDelta: 0.09, longitudeDelta: 0.09)))
            }
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
                        if showingDemo { settings = true } else { Task { await sync() } }
                    }.disabled(syncing)
                }
                if !showingDemo {
                    Button { activeTab = 1 } label: {
                        Label(hasHome ? String(format: "Alternatives within %.1f km of home · Edit", radius) : "Set home in Plan to find matched alternatives", systemImage: "house")
                            .font(.caption)
                    }
                }
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
        let matches = showingDemo ? demoAlternatives(for: run) : alternatives[run.id] ?? []
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
                Text(showingDemo ? "EXAMPLE ALTERNATIVES" : "MATCHED ALTERNATIVES")
                    .font(.caption2.bold()).tracking(1)
                Spacer()
                if loadingAlternatives.contains(run.id) { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<2, id: \.self) { index in
                    if index < matches.count {
                        alternativeTile(matches[index], run: run)
                    } else {
                        alternativePlaceholder(run, index: index, count: matches.count)
                    }
                }
            }
            if let error = alternativeErrors[run.id], !showingDemo {
                Text(error).font(.caption).foregroundStyle(.secondary)
                if hasHome && !loadingAlternatives.contains(run.id) {
                    Button("Retry alternatives") {
                        alternativeErrors[run.id] = nil
                        alternatives[run.id] = nil
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
    private func alternativeTile(_ route: Route, run: Run) -> some View {
        Button { detail = route } label: {
            VStack(alignment: .leading, spacing: 7) {
                RunMap(points: route.points, tint: accent, emptyText: "Map unavailable").frame(height: 105)
                Text(route.name).font(.caption.bold()).lineLimit(1)
                Text(String(format: "%.1f km · %.0f m ↑", route.distance / 1000, route.ascent))
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(route.match(distance: run.distance, ascent: run.total_elevation_gain))% similar")
                    .font(.caption.bold()).foregroundStyle(accent)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func alternativePlaceholder(_ run: Run, index: Int, count: Int) -> some View {
        let text: String
        if showingDemo { text = "Example map" }
        else if !hasHome { text = "Set home in Plan" }
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
        guard !showingDemo, !token.isEmpty, hasHome, let api,
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
            if result.routes.isEmpty { alternativeErrors[run.id] = "No similar loops found in your home radius. Try changing it in Plan." }
        } catch {
            guard context == feedContext else { return }
            if Task.isCancelled { return }
            alternativeErrors[run.id] = error.localizedDescription
        }
    }
    private func resetFeedMatches() {
        alternatives = [:]; alternativeErrors = [:]; loadingAlternatives = []
        feedVersion = UUID()
    }
    private var planner: some View {
        VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Plan your next run").font(.title2.bold())
                        Text("Match a planned workout, then explore a new loop.").font(.subheadline).foregroundStyle(.secondary)
                        slider("Distance", value: $target, range: 2...30, suffix: "km")
                        slider("Elevation gain", value: $climb, range: 0...800, suffix: "m")
                        slider("Stay within home", value: $radius, range: 1...20, suffix: "km")
                        Button { pickingHome.toggle() } label: { Label(pickingHome ? "Tap the map to place home" : "Choose home on map", systemImage: "house") }
                        Text("The initial map is an example location in Brisbane. Set your home before searching. Home stays on this device until you request routes. The routing provider then receives the start point.").font(.caption).foregroundStyle(.secondary)
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
                        Button { Task { await findRoutes() } } label: {
                            HStack { Spacer(); if busy { ProgressView().tint(.black) }; Text(busy ? "Finding your loops…" : "Find a different route").bold(); Image(systemName: "arrow.up.right"); Spacer() }.padding()
                        }.background(accent, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.black).disabled(busy)
                    }.padding(20).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
                    if let message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if !routes.isEmpty {
                        Text("Your alternative loops").font(.title2.bold())
                        Text("Similarity uses distance (70%) and climbing (30%). Surface, heat and technical terrain also affect effort. Review access and safety before running.").font(.caption).foregroundStyle(.secondary)
                        ForEach(sorted) { route in
                            Button { selected = route; camera = .automatic } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 8) { Text(route.name).font(.headline); Text(String(format: "%.1f km  ·  %.0f m climb", route.distance / 1000, route.ascent)).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text("\(route.match(distance: target * 1000, ascent: climb))%\nsimilar").font(.subheadline.bold()).foregroundStyle(accent)
                                }.padding(20).background(.white.opacity(selected?.id == route.id ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain)
                        }
                    }
        }
        .onChange(of: radius) { _, _ in resetFeedMatches(); routes = []; selected = nil }
        .onChange(of: target) { _, _ in routes = []; selected = nil }
        .onChange(of: climb) { _, _ in routes = []; selected = nil }
    }
    private var trend: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent distance trend").font(.headline)
            Chart(runs.reversed()) { run in
                BarMark(x: .value("Date", String(run.start_date.prefix(10))), y: .value("Distance (km)", run.km)).foregroundStyle(accent.gradient).cornerRadius(4)
            }.frame(height: 110).chartXAxis(.hidden)
            Text(String(format: "%.1f km across %d runs · %.0f m total climbing", runs.reduce(0) { $0 + $1.km }, runs.count, runs.reduce(0) { $0 + $1.total_elevation_gain })).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack { HStack { Text(title); Spacer(); Text(String(format: suffix == "m" ? "%.0f %@" : "%.1f %@", value.wrappedValue, suffix)).monospacedDigit().bold() }; Slider(value: value, in: range) }
    }
    private var settingsView: some View {
        NavigationStack { Form {
            Section("Backend") { TextField("HTTPS backend URL", text: $backend).textInputAutocapitalization(.never).autocorrectionDisabled(); Text("Deploy the included server and configure Strava and GraphHopper there.").font(.caption) }
            Section("Strava") {
                Button(token.isEmpty ? "Connect Strava" : "Reconnect Strava") { connect() }
                if !token.isEmpty { Button("Refresh runs") { Task { await sync() } }; Button("Disconnect", role: .destructive) { Task { await disconnect() } } }
            }
            if let message { Text(message) }
        }.onChange(of: backend) { _, _ in
            token = ""; SessionStore.save(nil); runs = demoRuns; showingDemo = true
            resetFeedMatches(); routes = []; selected = nil
        }.navigationTitle("Connections").toolbar { Button("Done") { settings = false } } }
    }
    private func connect() {
        guard let api else { message = "Enter a valid HTTPS backend URL."; return }
        let session = ASWebAuthenticationSession(url: api.base.appendingPathComponent("auth/strava"), callbackURLScheme: "runways") { url, error in
            Task { @MainActor in
                guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let ticket = parts.queryItems?.first(where: { $0.name == "ticket" })?.value else {
                    message = error?.localizedDescription ?? "Strava connection was not completed."; return
                }
                do {
                    let result: Session = try await api.get("auth/exchange", query: [.init(name: "ticket", value: ticket)])
                    token = result.session; SessionStore.save(token)
                    showingDemo = false; runs = []; resetFeedMatches(); await sync()
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
            let result: [Run] = try await api.get("runs")
            guard token == requestedToken, backend == requestedBackend else { return }
            runs = result; showingDemo = false; resetFeedMatches()
            message = result.isEmpty ? "No runs found in the latest 100 activities." : nil
        }
        catch { message = error.localizedDescription }
    }
    private func disconnect() async {
        guard let api else { return }
        do { let _: Session = try await api.get("disconnect"); token = ""; SessionStore.save(nil); runs = demoRuns; showingDemo = true; resetFeedMatches(); message = nil }
        catch { message = error.localizedDescription }
    }
    private func findRoutes() async {
        guard hasHome else { message = "Choose your home on the map before finding routes."; return }
        guard let api, !token.isEmpty else { message = "Connect Strava in Connections to generate live routes. Demo history is for exploring the interface."; return }
        busy = true; message = nil
        let requestedContext = feedContext
        let requestedTarget = target
        let requestedClimb = climb
        defer { busy = false }
        do {
            let response: RouteResponse = try await api.get("routes", query: ["lat": home.latitude, "lon": home.longitude, "distance": target * 1000, "ascent": climb, "radius": radius * 1000].map { .init(name: $0.key, value: String($0.value)) })
            guard feedContext == requestedContext, target == requestedTarget, climb == requestedClimb else { return }
            routes = response.routes; selected = sorted.first; camera = .automatic
            if routes.isEmpty { message = "No matching loops fit this radius. Increase the radius or adjust the distance and climbing." }
        } catch { message = error.localizedDescription }
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

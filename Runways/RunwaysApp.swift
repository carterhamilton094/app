import SwiftUI
import MapKit
import Charts
import AuthenticationServices

@main struct RunwaysApp: App {
    var body: some Scene { WindowGroup { Dashboard() } }
}

struct Dashboard: View {
    @AppStorage("backend") private var backend = "https://your-backend.example.com"
    @State private var token = SessionStore.read() ?? ""
    @State private var runs = demoRuns
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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("A familiar effort.").font(.largeTitle.bold())
                            Text("A different way home.").font(.largeTitle.bold()).foregroundStyle(accent)
                        }
                        Spacer()
                    }
                    Text(token.isEmpty ? "DEMO DATA · Connect Strava for your running history" : "YOUR STRAVA TRAINING").font(.caption.bold()).foregroundStyle(.secondary)
                    trend
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
                    Text("Recent runs").font(.title2.bold())
                    ForEach(runs.prefix(6)) { run in
                        Button { target = run.km; climb = run.total_elevation_gain } label: {
                            HStack { Image(systemName: "figure.run").foregroundStyle(accent); VStack(alignment: .leading) { Text(run.name); Text(String(format: "%.1f km · %.0f m · %@ /km", run.km, run.total_elevation_gain, run.pace)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.up.left") }.padding(.vertical, 8)
                        }.buttonStyle(.plain)
                    }
                    Text("Tap a recent run to use its distance and climbing as your target. Route generation requires a configured backend; demo history does not represent your Strava account.").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.background(Color(red: 0.055, green: 0.075, blue: 0.065)).navigationTitle("RUNWAYS").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button { settings = true } label: { Image(systemName: "slider.horizontal.3") } }
                .sheet(isPresented: $settings) { settingsView }
                .task {
                    if UserDefaults.standard.object(forKey: "homeLat") != nil {
                        home = .init(latitude: UserDefaults.standard.double(forKey: "homeLat"), longitude: UserDefaults.standard.double(forKey: "homeLon"))
                        camera = .region(.init(center: home, span: .init(latitudeDelta: 0.09, longitudeDelta: 0.09)))
                    }
                    if !token.isEmpty { await sync() }
                }
        }.preferredColorScheme(.dark).tint(accent)
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
                    token = result.session; SessionStore.save(token); await sync()
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
        do { let result: [Run] = try await api.get("runs"); runs = result; message = result.isEmpty ? "No runs found in the latest 100 activities." : nil }
        catch { message = error.localizedDescription }
    }
    private func disconnect() async {
        guard let api else { return }
        do { let _: Session = try await api.get("disconnect"); token = ""; SessionStore.save(nil); runs = demoRuns; message = nil }
        catch { message = error.localizedDescription }
    }
    private func findRoutes() async {
        guard let api, !token.isEmpty else { message = "Connect Strava in Connections to generate live routes. Demo history is for exploring the interface."; return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let response: RouteResponse = try await api.get("routes", query: ["lat": home.latitude, "lon": home.longitude, "distance": target * 1000, "ascent": climb, "radius": radius * 1000].map { .init(name: $0.key, value: String($0.value)) })
            routes = response.routes; selected = sorted.first; camera = .automatic
            if routes.isEmpty { message = "No matching loops fit this radius. Increase the radius or adjust the distance and climbing." }
        } catch { message = error.localizedDescription }
    }
}
final class AuthWindow: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthWindow()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

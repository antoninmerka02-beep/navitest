import SwiftUI
import UIKit
import CoreLocation
import MapKit
import ExternalAccessory

// MARK: - Poloha (zároveň drží appku naživu na pozadí)
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let lm = CLLocationManager()
    var onLocation: ((CLLocation) -> Void)?
    private(set) var last: CLLocation?

    func start() {
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        lm.distanceFilter = kCLDistanceFilterNone
        lm.pausesLocationUpdatesAutomatically = false
        lm.activityType = .automotiveNavigation
        lm.allowsBackgroundLocationUpdates = true
        lm.showsBackgroundLocationIndicator = true
        if lm.authorizationStatus == .notDetermined { lm.requestWhenInUseAuthorization() }
        lm.startUpdatingLocation()
        log("GPS zapnuto (oprávnění: \(lm.authorizationStatus.rawValue))")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        log("Oprávnění k poloze: \(manager.authorizationStatus.rawValue) (4 = při používání, 3 = vždy)")
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        last = l
        onLocation?(l)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log("⚠️ Poloha: \(error.localizedDescription)")
    }
}

// MARK: - Model aplikace
final class AppModel: ObservableObject {
    @Published var status = SessionStatus()
    @Published var accessories: [String] = []
    @Published var selfTestSummary = ""
    @Published var opts = TestOptions() { didSet { session.options = opts } }
    @Published var autoConnect = true

    // Navigace
    @Published var query = ""
    @Published var results: [MKMapItem] = []
    @Published var searching = false
    @Published var routeSummary = ""
    @Published var routeSteps: [String] = []
    @Published var calculating = false
    @Published var avoidHighways = false
    @Published var avoidTolls = false
    @Published var gpsText = "–"

    let navigator = Navigator()
    let snapshots = MapSnapshotProvider()
    lazy var session = DashSession(navigator: navigator, snapshots: snapshots)
    private let location = LocationService()
    private var destination: MKMapItem?
    private var lastGpsUI = Date.distantPast

    init() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        log("NaviTest \(v) spuštěn, iOS \(UIDevice.current.systemVersion)")
        session.options = opts
        session.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        session.onBikeCommand = { [weak self] svc in self?.bikeCommand(svc) }
        navigator.onReroute = { [weak self] loc in self?.reroute(from: loc) }

        let t = NL.selfTest()
        selfTestSummary = "\(t.passed)/\(t.total) \(t.passed == t.total ? "OK" : "CHYBA")"
        log("Self-test protokolu: \(selfTestSummary)")
        t.lines.filter { $0.hasPrefix("❌") }.forEach { log("   \($0)") }

        location.onLocation = { [weak self] loc in
            guard let self = self else { return }
            self.navigator.update(loc)
            if Date().timeIntervalSince(self.lastGpsUI) > 1 {
                self.lastGpsUI = Date()
                let kmh = max(0, loc.speed * 3.6)
                self.gpsText = String(format: "±%.0f m · %.0f km/h · kurz %.0f°", loc.horizontalAccuracy, kmh, max(0, loc.course))
            }
        }
        location.start()
        _ = TileStore.shared   // zjistí aktuální adresu mapových dlaždic

        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(forName: .EAAccessoryDidConnect, object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            if let a = n.userInfo?[EAAccessoryKey] as? EAAccessory { log("🔌 Připojeno: \(DashLink.describe(a))") }
            self.refreshAccessories()
            if self.autoConnect, !self.session.isRunning,
               let a = n.userInfo?[EAAccessoryKey] as? EAAccessory, a.protocolStrings.contains(DashLink.proto) {
                log("Auto-připojení…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.session.start() }
            }
        }
        NotificationCenter.default.addObserver(forName: .EAAccessoryDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[EAAccessoryKey] as? EAAccessory { log("🔌 Odpojeno: \(a.name)") }
            self?.refreshAccessories()
        }
        refreshAccessories()
        if autoConnect, DashLink.findAccessory() != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.session.start() }
        }
    }

    func refreshAccessories() {
        accessories = EAAccessoryManager.shared().connectedAccessories.map { DashLink.describe($0) }
    }

    // MARK: Hledání cíle
    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if let loc = location.last {
            req.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 100_000, longitudinalMeters: 100_000)
        }
        searching = true
        MKLocalSearch(request: req).start { [weak self] resp, err in
            guard let self = self else { return }
            self.searching = false
            if let err = err { log("❌ Hledání: \(err.localizedDescription)"); self.results = []; return }
            self.results = Array((resp?.mapItems ?? []).prefix(8))
            log("🔎 „\(q)“: \(self.results.count) výsledků")
        }
    }

    static func describe(_ item: MKMapItem) -> String {
        let p = item.placemark
        let parts = [p.thoroughfare.map { t in [t, p.subThoroughfare].compactMap { $0 }.joined(separator: " ") }, p.locality]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Trasa
    func navigate(to item: MKMapItem) {
        destination = item
        results = []
        calculate(from: MKMapItem.forCurrentLocation(), reason: "nová trasa")
    }

    private func reroute(from loc: CLLocation) {
        guard destination != nil, !calculating else { return }
        log("↪️ Sjetí z trasy – přepočítávám…")
        calculate(from: MKMapItem(placemark: MKPlacemark(coordinate: loc.coordinate)), reason: "přepočet")
    }

    private func calculate(from source: MKMapItem, reason: String) {
        guard let dest = destination else { return }
        let req = MKDirections.Request()
        req.source = source
        req.destination = dest
        req.transportType = .automobile
        req.requestsAlternateRoutes = false
        req.highwayPreference = avoidHighways ? .avoid : .any
        req.tollPreference = avoidTolls ? .avoid : .any
        calculating = true
        let name = dest.name ?? "Cíl"
        MKDirections(request: req).calculate { [weak self] resp, err in
            guard let self = self else { return }
            self.calculating = false
            guard let route = resp?.routes.first else {
                log("❌ Trasa (\(reason)): \(err?.localizedDescription ?? "žádná trasa")")
                return
            }
            let r = NavRoute(route: route, destinationName: name)
            self.navigator.setRoute(r)
            self.routeSummary = String(format: "%@ · %.1f km · %.0f min · %ld manévrů",
                                       name, r.total / 1000, route.expectedTravelTime / 60, r.maneuvers.count)
            self.routeSteps = r.maneuvers.map { m in
                let (d, u) = formatDistance(m.at)
                let ds = u == "m" ? "\(Int(d)) m" : String(format: "%.1f km", d)
                return "\(ds) · \(TurnIcon.name(m.icon)) (\(m.icon)) · \(m.text)"
            }
            log("🧭 Trasa (\(reason)): \(self.routeSummary)")
            for s in self.routeSteps { log("   \(s)") }
            let n = TileStore.shared.prefetchRoute(r.points)
            log("🗺️ Předstahuji \(n) mapových dlaždic podél trasy")
            if self.opts.navSource != .real { self.opts.navSource = .real }
        }
    }

    func endNavigation() {
        destination = nil
        navigator.setRoute(nil)
        routeSummary = ""
        routeSteps = []
        log("🛑 Navigace ukončena")
    }

    private func bikeCommand(_ svc: UInt8) {
        switch svc {
        case 49: if destination != nil { endNavigation() }
        default: break
        }
    }

    // MARK: Test varování (formát přesně jako StreetCross)
    private var warningToken = 0

    func testWarning(_ kind: Int) {
        switch kind {
        case 0: showWarning(NL.speedCamera(limit: "50 km/h", distance: "300 m", cameraType: 0, show: true), clear: NL.speedCameraClear())
        case 1: showWarning(NL.speedCamera(limit: "90 km/h", distance: "1.2 km", cameraType: 3, show: true), clear: NL.speedCameraClear())
        case 2: showWarning(NL.speedCamera(limit: "50 km/h", distance: "150 m", cameraType: 5, show: true), clear: NL.speedCameraClear())
        case 3: showWarning(NL.speedCamera(limit: "50 km/h", distance: "400 m", cameraType: 2, show: true), clear: NL.speedCameraClear())
        case 4: showWarning(NL.schoolZone(distance: "200 m", show: true), clear: NL.schoolZone(distance: "", show: false))
        case 5: showWarning(NL.border(country: true, distance: "2 km", show: true), clear: NL.border(country: true, distance: "", show: false))
        case 6: session.enqueue([NL.speedingEvent()])
        default:
            warningToken += 1
            session.enqueue([NL.speedCameraClear(),
                             NL.schoolZone(distance: "", show: false),
                             NL.border(country: true, distance: "", show: false),
                             NL.naviEvent(type: 1, text: "", show: false)])
        }
    }

    /// Ukáže varování a za 12 s ho zase schová (když mezitím nepřišlo jiné).
    private func showWarning(_ m: NLMessage, clear: NLMessage) {
        warningToken += 1
        let token = warningToken
        session.enqueue([m])
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.warningToken == token else { return }
            self.session.enqueue([clear])
        }
    }
}

// MARK: - UI
struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var logs = Log.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            List {
                statusSection
                navigationSection
                mapSection
                sendSection
                warningSection
                controlSection
                Section("Příslušenství (MFi)") {
                    if m.accessories.isEmpty { Text("žádné").foregroundStyle(.secondary) }
                    ForEach(m.accessories, id: \.self) { Text($0).font(.caption) }
                    Button("Obnovit") { m.refreshAccessories() }
                }
                Section("Log") {
                    ShareLink(item: Log.shared.fileURL) { Label("Exportovat celý log", systemImage: "square.and.arrow.up") }
                    ForEach(Array(logs.lines.enumerated().reversed()), id: \.offset) { item in
                        Text(item.element).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .navigationTitle("NaviTest R9")
        }
        .onChange(of: phase) { p in
            switch p {
            case .background: log("📱 Aplikace na pozadí")
            case .active: log("📱 Aplikace aktivní")
            case .inactive: log("📱 Aplikace neaktivní")
            @unknown default: break
            }
        }
    }

    private var statusSection: some View {
        Section("Stav") {
            row("Spojení", m.status.phase)
            row("Přístrojovka", "\(m.status.partNumber) · \(m.status.model.rawValue)")
            row("Režim (dle motorky)", m.status.mode.rawValue)
            row("Obrázky", String(format: "%.1f fps · %ld kB · potvrzeno %ld",
                                  m.status.fps, m.status.lastKB, m.status.imagesAcked))
            row("Zoom", m.status.zoomText)
            row("Mapa", m.status.mapStats.isEmpty ? "–" : m.status.mapStats)
            row("GPS", m.gpsText)
            row("Self-test", m.selfTestSummary)
        }
    }

    private var navigationSection: some View {
        Section("Navigace") {
            Picker("Zdroj", selection: $m.opts.navSource) {
                ForEach(NavSource.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                TextField("Kam jedeme?", text: $m.query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { m.search() }
                Button(m.searching ? "…" : "Hledat") { m.search() }
            }
            ForEach(m.results, id: \.self) { item in
                Button {
                    m.navigate(to: item)
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "?")
                        Text(AppModel.describe(item)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("Vyhnout se dálnicím", isOn: $m.avoidHighways)
            Toggle("Vyhnout se placeným úsekům", isOn: $m.avoidTolls)
            if m.calculating { Text("Počítám trasu…").foregroundStyle(.secondary) }
            if !m.routeSummary.isEmpty {
                Text(m.routeSummary).font(.callout.bold())
                ForEach(Array(m.routeSteps.enumerated()), id: \.offset) { s in
                    Text(s.element).font(.caption)
                }
                Button("Ukončit navigaci", role: .destructive) { m.endNavigation() }
            }
        }
    }

    private var mapSection: some View {
        Section {
            Picker("Podklad", selection: $m.opts.mapSource) {
                ForEach(MapSource.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Šipka a vzdálenost v obrázku", isOn: $m.opts.turnBox)
            Toggle("Sever nahoře (jinak po směru jízdy)", isOn: $m.opts.northUp)
            Toggle("Tmavá mapa", isOn: $m.opts.darkMap)
        } header: {
            Text("Mapa v motorce")
        } footer: {
            Text("Mapová data © přispěvatelé OpenStreetMap, dlaždice OpenFreeMap a © OpenMapTiles. Apple mapa funguje jen s odemčeným telefonem.")
        }
    }

    private var sendSection: some View {
        Section("Co posílat") {
            Toggle("Obrázky mapy", isOn: $m.opts.sendImages)
            Toggle("Navigační data (šipky, vzdálenost)", isOn: $m.opts.sendNavData)
            Picker("Navigační služba", selection: $m.opts.navService) {
                ForEach(NavServiceChoice.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Stepper("Obrázky: \(Int(m.opts.imageFps)) fps", value: $m.opts.imageFps, in: 1...6, step: 1)
            VStack(alignment: .leading) {
                Text("Kvalita JPEG: \(Int(m.opts.jpegQuality * 100)) %")
                Slider(value: $m.opts.jpegQuality, in: 0.2...0.9, step: 0.05)
            }
        }
    }

    private var warningSection: some View {
        Section("Varování (test)") {
            HStack {
                Button("Radar 50") { m.testWarning(0) }.buttonStyle(.bordered)
                Button("Úsekové 90") { m.testWarning(1) }.buttonStyle(.bordered)
                Button("Červená") { m.testWarning(2) }.buttonStyle(.bordered)
            }
            HStack {
                Button("Mobilní") { m.testWarning(3) }.buttonStyle(.bordered)
                Button("Škola") { m.testWarning(4) }.buttonStyle(.bordered)
                Button("Hranice") { m.testWarning(5) }.buttonStyle(.bordered)
            }
            HStack {
                Button("Rychlost") { m.testWarning(6) }.buttonStyle(.bordered)
                Button("Zrušit vše", role: .destructive) { m.testWarning(9) }.buttonStyle(.bordered)
            }
        }
    }

    private var controlSection: some View {
        Section("Ovládání") {
            HStack {
                Button("Připojit") { m.session.start() }.buttonStyle(.borderedProminent)
                Spacer()
                Button("Odpojit", role: .destructive) { m.session.stop() }.buttonStyle(.bordered)
            }
            Toggle("Auto-připojení k motorce", isOn: $m.autoConnect)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}

@main
struct NaviTestApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}

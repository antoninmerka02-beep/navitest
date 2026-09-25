import SwiftUI
import UIKit
import CoreLocation
import MapKit
import ExternalAccessory
import Combine

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

// MARK: - Uložená nastavení
struct AssistSettings: Codable {
    var cameras = true
    var schools = true
    var borders = true
    var speeding = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AssistSettings()
        cameras = (try? c.decodeIfPresent(Bool.self, forKey: .cameras)) ?? d.cameras
        schools = (try? c.decodeIfPresent(Bool.self, forKey: .schools)) ?? d.schools
        borders = (try? c.decodeIfPresent(Bool.self, forKey: .borders)) ?? d.borders
        speeding = (try? c.decodeIfPresent(Bool.self, forKey: .speeding)) ?? d.speeding
    }
}

struct SavedSettings: Codable {
    var opts = TestOptions()
    var autoConnect = true
    var avoidHighways = false
    var avoidTolls = false
    var assist = AssistSettings()
    var language: AppLanguage = .en
    var voice = VoiceSettings()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SavedSettings()
        language = (try? c.decodeIfPresent(AppLanguage.self, forKey: .language)) ?? d.language
        voice = (try? c.decodeIfPresent(VoiceSettings.self, forKey: .voice)) ?? d.voice
        opts = (try? c.decodeIfPresent(TestOptions.self, forKey: .opts)) ?? d.opts
        autoConnect = (try? c.decodeIfPresent(Bool.self, forKey: .autoConnect)) ?? d.autoConnect
        avoidHighways = (try? c.decodeIfPresent(Bool.self, forKey: .avoidHighways)) ?? d.avoidHighways
        avoidTolls = (try? c.decodeIfPresent(Bool.self, forKey: .avoidTolls)) ?? d.avoidTolls
        assist = (try? c.decodeIfPresent(AssistSettings.self, forKey: .assist)) ?? d.assist
    }

    static let key = "settings.v1"
    static func load() -> SavedSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(SavedSettings.self, from: d) else { return SavedSettings() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: SavedSettings.key) }
    }
}

// MARK: - Model aplikace
final class AppModel: ObservableObject {
    // Stav a nastavení
    @Published var status = SessionStatus()
    @Published var accessories: [String] = []
    @Published var selfTestSummary = ""
    @Published var selfTestLines: [String] = []
    @Published var opts = TestOptions() {
        didSet {
            session.options = opts
            saveSettings()
            if opts.tileURL != oldValue.tileURL { TileStore.shared.configure(url: opts.tileURL) }
        }
    }
    @Published var autoConnect = true { didSet { saveSettings() } }
    @Published var avoidHighways = false { didSet { saveSettings() } }
    @Published var avoidTolls = false { didSet { saveSettings() } }
    @Published var assist = AssistSettings() { didSet { saveSettings() } }
    @Published var language: AppLanguage = .en {
        didSet { L10n.lang = language; saveSettings(); pushBikeFavorites() }
    }
    @Published var voiceSettings = VoiceSettings() { didSet { voice.settings = voiceSettings; saveSettings() } }
    @Published var gpsText = "–"

    // Navigace
    @Published var selectedPlace: Place? = nil
    @Published var destination: Place? = nil
    @Published var guidance: NavSnapshot? = nil
    @Published var routeSummary = ""
    @Published var routeSteps: [String] = []
    @Published var routeCoords: [CLLocationCoordinate2D] = []
    @Published var routeVersion = 0
    @Published var calculating = false
    @Published var recenterToken = 0
    @Published var toast: String? = nil
    @Published var searchResults: [Place] = []
    @Published var searchingNearby = false
    @Published var phoneNight = false

    let places = PlacesStore()
    let completer = SearchCompleter()
    let navigator = Navigator()
    let snapshots = MapSnapshotProvider()
    lazy var session = DashSession(navigator: navigator, snapshots: snapshots)
    private let location = LocationService()
    let voice = VoiceGuide()
    private var lastGpsUI = Date.distantPast
    private var bag = Set<AnyCancellable>()

    var currentLocation: CLLocation? { location.last }
    var bikeConnected: Bool { status.phase == "Connected" }
    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    init() {
        let saved = SavedSettings.load()
        L10n.lang = saved.language
        language = saved.language
        voiceSettings = saved.voice
        voice.settings = saved.voice
        log("NaviTest \(version) spuštěn, iOS \(UIDevice.current.systemVersion), jazyk \(saved.language.rawValue)")
        opts = saved.opts
        autoConnect = saved.autoConnect
        avoidHighways = saved.avoidHighways
        avoidTolls = saved.avoidTolls
        assist = saved.assist
        session.options = opts

        // Změny v místech a našeptávači překreslí i obrazovky navázané na AppModel
        places.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        completer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)

        session.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        session.onBikeCommand = { [weak self] svc in self?.bikeCommand(svc) }
        session.onBikeNavigate = { [weak self] fav in self?.navigateFromBike(fav) }
        navigator.onReroute = { [weak self] loc in self?.reroute(from: loc) }

        let t = NL.selfTest()
        selfTestSummary = "\(t.passed)/\(t.total) \(t.passed == t.total ? "OK" : "CHYBA")"
        selfTestLines = t.lines
        log("Self-test protokolu: \(selfTestSummary)")
        t.lines.filter { $0.hasPrefix("❌") }.forEach { log("   \($0)") }

        location.onLocation = { [weak self] loc in
            guard let self = self else { return }
            self.navigator.update(loc)
            // Hlas jede z polohy – funguje i se zamčeným telefonem
            if self.navigator.hasRoute, let snap = self.navigator.snapshot() {
                self.voice.update(snap, speed: max(0, loc.speed))
            }
            if Date().timeIntervalSince(self.lastGpsUI) > 1 {
                self.lastGpsUI = Date()
                self.gpsText = String(format: "±%.0f m · %.0f km/h · kurz %.0f°",
                                      loc.horizontalAccuracy, max(0, loc.speed * 3.6), max(0, loc.course))
            }
        }
        location.start()
        TileStore.shared.configure(url: opts.tileURL)
        session.onGasRequest = { [weak self] in self?.searchGasForBike() }
        pushBikeFavorites()

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

    // MARK: Nastavení
    private func saveSettings() {
        var s = SavedSettings()
        s.opts = opts
        s.autoConnect = autoConnect
        s.avoidHighways = avoidHighways
        s.avoidTolls = avoidTolls
        s.assist = assist
        s.language = language
        s.voice = voiceSettings
        s.save()
    }

    /// Tovární nastavení: nastavení, oblíbená místa i historie (mapová data v telefonu zůstávají).
    func factoryReset() {
        UserDefaults.standard.removeObject(forKey: SavedSettings.key)
        let d = SavedSettings()
        opts = d.opts
        autoConnect = d.autoConnect
        avoidHighways = d.avoidHighways
        avoidTolls = d.avoidTolls
        assist = d.assist
        language = d.language
        voiceSettings = d.voice
        Log.shared.enabled = false
        places.clearAll()
        pushBikeFavorites()
        session.resetZoom()
        log("♻️ Obnoveno tovární nastavení")
        flash(T("Factory settings restored"))
    }

    func refreshAccessories() {
        accessories = EAAccessoryManager.shared().connectedAccessories.map { DashLink.describe($0) }
    }

    func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: Hledání
    func select(_ s: Suggestion) {
        if let p = s.place { selectedPlace = p; return }
        guard let c = s.completion else { return }
        let req = MKLocalSearch.Request(completion: c)
        if let l = currentLocation {
            req.region = MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }
        MKLocalSearch(request: req).start { [weak self] resp, err in
            guard let self = self else { return }
            let items = resp?.mapItems ?? []
            if items.count > 1 {
                // Řetězec / kategorie (např. Kaufland) → všechny pobočky v okolí od nejbližší
                self.showResults(items.map { Place.from($0) })
                return
            }
            guard let item = items.first else {
                log("❌ Místo se nepodařilo dohledat: \(err?.localizedDescription ?? "?")")
                self.flash(T("Place could not be found"))
                return
            }
            var p = Place.from(item)
            p.name = s.title
            if !s.subtitle.isEmpty { p.subtitle = s.subtitle }
            self.selectedPlace = p
        }
    }

    /// Potvrzení hledání bez výběru návrhu: všechny výsledky v okolí jako seznam a špendlíky.
    func searchNearby(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if let l = currentLocation {
            req.region = MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }
        searchingNearby = true
        MKLocalSearch(request: req).start { [weak self] resp, err in
            guard let self = self else { return }
            self.searchingNearby = false
            let items = resp?.mapItems ?? []
            if items.isEmpty { self.flash(T("No results")); return }
            if items.count == 1 { self.selectedPlace = Place.from(items[0]); return }
            self.showResults(items.map { Place.from($0) })
        }
    }

    private func showResults(_ places: [Place]) {
        selectedPlace = nil
        searchResults = sortedByDistance(places)
        log("🔎 Výsledků v okolí: \(searchResults.count)")
    }

    func clearResults() { searchResults = [] }

    func sortedByDistance(_ ps: [Place]) -> [Place] {
        guard let here = currentLocation else { return ps }
        return ps.sorted {
            here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) <
            here.distance(from: CLLocation(latitude: $1.lat, longitude: $1.lon))
        }
    }

    /// Klepnutí na místo v mapě telefonu (obchod, benzínka…).
    func selectMapItem(_ item: MKMapItem) {
        selectedPlace = Place.from(item)
    }

    /// Podržení prstu v mapě: špendlík s adresou.
    func dropPin(at c: CLLocationCoordinate2D) {
        var p = Place(kind: .history, name: T("Dropped pin"), subtitle: "", lat: c.latitude, lon: c.longitude)
        selectedPlace = p
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)) { [weak self] pms, _ in
            guard let self = self, let pm = pms?.first, self.selectedPlace?.id == p.id else { return }
            let street = [pm.thoroughfare, pm.subThoroughfare].compactMap { $0 }.joined(separator: " ")
            p.name = street.isEmpty ? (pm.name ?? p.name) : street
            p.subtitle = pm.locality ?? ""
            self.selectedPlace = p
        }
    }

    // MARK: Čerpací stanice pro motorku
    private var gasSearchToken = 0
    private var gasAnswered = false

    /// Motorka chce „Nearby Gas Stations“: Apple Mapy (funguje i se zamčeným telefonem);
    /// když neodpoví do 8 s nebo nic nenajdou, vezmou se čerpací stanice z uložených map.
    private func searchGasForBike() {
        guard let here = currentLocation else {
            session.provideGasStations([])
            log("⛽ Bez polohy – prázdný seznam")
            return
        }
        gasSearchToken += 1
        let token = gasSearchToken
        gasAnswered = false
        let req = MKLocalPointsOfInterestRequest(center: here.coordinate, radius: 15_000)
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation])
        MKLocalSearch(request: req).start { [weak self] resp, err in
            guard let self = self else { return }
            let items = resp?.mapItems ?? []
            if items.isEmpty {
                if let err = err { log("⚠️ Apple hledání čerpacích stanic: \(err.localizedDescription)") }
                self.gasFallback(token: token, here: here)
            } else {
                self.finishGas(items.map { BikeFav(name: $0.name ?? "⛽", coordinate: $0.placemark.coordinate, tag: "gas") },
                               source: "Apple", token: token, here: here)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.gasFallback(token: token, here: here)
        }
    }

    private func gasFallback(token: Int, here: CLLocation) {
        guard token == gasSearchToken, !gasAnswered else { return }
        let osm = TileStore.shared.fuelStations(near: here.coordinate)
        finishGas(osm.map { BikeFav(name: $0.name, coordinate: $0.coordinate, tag: "gas") },
                  source: "OpenStreetMap", token: token, here: here)
    }

    private func finishGas(_ list: [BikeFav], source: String, token: Int, here: CLLocation) {
        guard token == gasSearchToken, !gasAnswered else { return }
        gasAnswered = true
        let sorted = list.sorted {
            here.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) <
            here.distance(from: CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude))
        }
        session.provideGasStations(Array(sorted.prefix(20)))
        log("⛽ Čerpací stanice (\(source)): \(min(20, sorted.count))")
    }

    // MARK: Den / noc v telefonu
    func refreshNight() {
        let n: Bool
        switch opts.dayNight {
        case .day: n = false
        case .night: n = true
        case .auto: n = isNight(at: currentLocation?.coordinate)
        }
        if n != phoneNight { phoneNight = n }
    }

    func distanceText(to p: Place) -> String? {
        guard let here = currentLocation else { return nil }
        let d = here.distance(from: CLLocation(latitude: p.lat, longitude: p.lon))
        return d < 1000 ? TF("%ld m as the crow flies", Int(d / 10) * 10) : TF("%.1f km as the crow flies", d / 1000)
    }

    // MARK: Oblíbená místa
    func setHome(_ p: Place) { places.setHome(p); pushBikeFavorites(); flash(T("Saved as Home")) }
    func setWork(_ p: Place) { places.setWork(p); pushBikeFavorites(); flash(T("Saved as Work")) }
    func addFavorite(_ p: Place) { places.addFavorite(p); pushBikeFavorites(); flash(T("Added to favorites")) }
    func removePlace(_ p: Place) { places.remove(p); pushBikeFavorites() }
    func clearHistory() { places.clearHistory(); pushBikeFavorites() }

    /// Seznam pro přístrojovku: Domů, Práce, oblíbené, pak poslední cíle.
    private func pushBikeFavorites() {
        var list: [BikeFav] = []
        if let h = places.home { list.append(BikeFav(name: T("Home"), coordinate: h.coordinate, tag: "home")) }
        if let w = places.work { list.append(BikeFav(name: T("Work"), coordinate: w.coordinate, tag: "work")) }
        for p in places.others { list.append(BikeFav(name: p.name, coordinate: p.coordinate, tag: p.id.uuidString)) }
        for p in places.history.prefix(5) { list.append(BikeFav(name: p.name, coordinate: p.coordinate, tag: p.id.uuidString)) }
        session.setBikeFavorites(list, home: places.home != nil, office: places.work != nil)
    }

    // MARK: Trasa
    private var destinationItem: MKMapItem?

    func navigate(to p: Place) {
        places.addHistory(p)
        pushBikeFavorites()
        destination = p
        selectedPlace = nil
        destinationItem = p.mapItem
        if opts.navSource != .real { opts.navSource = .real }
        calculate(from: MKMapItem.forCurrentLocation(), reason: "nová trasa")
    }

    private func navigateFromBike(_ fav: BikeFav) {
        let all = places.favorites + places.history
        if fav.tag == "home", let h = places.home { navigate(to: h) }
        else if fav.tag == "work", let w = places.work { navigate(to: w) }
        else if let p = all.first(where: { $0.id.uuidString == fav.tag }) { navigate(to: p) }
        else { navigate(to: Place(kind: .history, name: fav.name, subtitle: "", lat: fav.coordinate.latitude, lon: fav.coordinate.longitude)) }
    }

    private func reroute(from loc: CLLocation) {
        guard destinationItem != nil, !calculating else { return }
        log("↪️ Sjetí z trasy – přepočítávám…")
        calculate(from: MKMapItem(placemark: MKPlacemark(coordinate: loc.coordinate)), reason: "přepočet")
    }

    private func calculate(from source: MKMapItem, reason: String) {
        guard let dest = destinationItem else { return }
        let req = MKDirections.Request()
        req.source = source
        req.destination = dest
        req.transportType = .automobile
        req.requestsAlternateRoutes = false
        req.highwayPreference = avoidHighways ? .avoid : .any
        req.tollPreference = avoidTolls ? .avoid : .any
        calculating = true
        let name = destination?.name ?? dest.name ?? T("Destination")
        MKDirections(request: req).calculate { [weak self] resp, err in
            guard let self = self else { return }
            self.calculating = false
            guard let route = resp?.routes.first else {
                log("❌ Trasa (\(reason)): \(err?.localizedDescription ?? "žádná trasa")")
                self.flash(T("Route could not be calculated"))
                return
            }
            let r = NavRoute(route: route, destinationName: name)
            self.navigator.setRoute(r)
            self.voice.routeStarted(generation: self.navigator.routeGeneration, reroute: reason == "přepočet")
            self.routeCoords = r.points.map { $0.coordinate }
            self.routeVersion += 1
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
            self.refreshGuidance()
        }
    }

    func endNavigation() {
        destinationItem = nil
        destination = nil
        navigator.setRoute(nil)
        routeSummary = ""
        routeSteps = []
        routeCoords = []
        routeVersion += 1
        guidance = nil
        voice.reset()
        log("🛑 Navigace ukončena")
    }

    func refreshGuidance() {
        guidance = navigator.hasRoute ? navigator.snapshot() : nil
    }

    private func bikeCommand(_ svc: UInt8) {
        switch svc {
        case 49:
            if destination != nil { endNavigation() }
        case 53:
            if let h = places.home { navigate(to: h) } else { log("⚠️ Motorka chce domů, ale Domov není nastaven") }
        case 54:
            if let w = places.work { navigate(to: w) } else { log("⚠️ Motorka chce do práce, ale Práce není nastavena") }
        default: break
        }
    }

    // MARK: Test varování (formát i rušení přesně jako StreetCross)
    enum WarnKind: Int { case camera, school, border }
    private var activeWarnings: [WarnKind: Int] = [:]
    private var warningToken = 0

    func testWarning(_ kind: Int) {
        switch kind {
        case 0: showWarning(.camera, NL.speedCamera(limit: "50 km/h", distance: "300 m", cameraType: 0, show: true))
        case 1: showWarning(.camera, NL.speedCamera(limit: "90 km/h", distance: "1.2 km", cameraType: 3, show: true))
        case 2: showWarning(.camera, NL.speedCamera(limit: "50 km/h", distance: "150 m", cameraType: 5, show: true))
        case 3: showWarning(.camera, NL.speedCamera(limit: "50 km/h", distance: "400 m", cameraType: 2, show: true))
        case 4: showWarning(.school, NL.schoolZone(distance: "200 m", show: true))
        case 5: showWarning(.border, NL.border(country: true, distance: "2 km"))
        case 6: session.enqueue([NL.speedingEvent()])
        default:
            for k in Array(activeWarnings.keys) { clearWarning(k) }
        }
    }

    private func showWarning(_ kind: WarnKind, _ m: NLMessage) {
        warningToken += 1
        let token = warningToken
        activeWarnings[kind] = token
        session.enqueue([m])
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.activeWarnings[kind] == token else { return }
            self.clearWarning(kind)
        }
    }

    private func clearWarning(_ kind: WarnKind) {
        guard activeWarnings.removeValue(forKey: kind) != nil else { return }
        switch kind {
        case .camera: session.enqueue([NL.speedCameraClear()])
        case .school: session.enqueue([NL.schoolZoneClear()])
        case .border: session.enqueue([NL.borderClear()])
        }
    }
}

@main
struct NaviTestApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(model)
                .preferredColorScheme(model.phoneNight ? .dark : .light)
        }
    }
}

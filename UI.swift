import SwiftUI
import MapKit

// MARK: - Mapa v telefonu (Apple mapa – telefon se na ni díváš jen odemčený)
/// Špendlík výsledku hledání.
final class PlacePin: MKPointAnnotation {
    var place: Place?
}

struct PhoneMapView: UIViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MKMapView {
        let v = MKMapView()
        v.delegate = context.coordinator
        v.showsUserLocation = true
        v.userTrackingMode = .follow
        v.showsCompass = true
        v.selectableMapFeatures = [.pointsOfInterest]      // klepnutí na obchod, benzínku…
        let lp = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        lp.minimumPressDuration = 0.5
        v.addGestureRecognizer(lp)
        context.coordinator.mapView = v
        return v
    }

    func updateUIView(_ v: MKMapView, context: Context) {
        let c = context.coordinator
        if c.routeVersion != model.routeVersion {
            c.routeVersion = model.routeVersion
            v.removeOverlays(v.overlays)
            if let a = c.destPin { v.removeAnnotation(a); c.destPin = nil }
            if model.routeCoords.count > 1 {
                let line = MKPolyline(coordinates: model.routeCoords, count: model.routeCoords.count)
                v.addOverlay(line)
                v.setVisibleMapRect(line.boundingMapRect,
                                    edgePadding: UIEdgeInsets(top: 150, left: 40, bottom: 240, right: 40), animated: true)
            }
            if let d = model.destination {
                let a = MKPointAnnotation()
                a.coordinate = d.coordinate
                a.title = d.name
                v.addAnnotation(a)
                c.destPin = a
            }
        }
        // Špendlíky výsledků hledání
        let ids = model.searchResults.map { $0.id }
        if c.resultIds != ids {
            c.resultIds = ids
            v.removeAnnotations(c.resultPins)
            c.resultPins = model.searchResults.map { p in
                let a = PlacePin()
                a.coordinate = p.coordinate
                a.title = p.name
                a.subtitle = model.distanceText(to: p)
                a.place = p
                return a
            }
            v.addAnnotations(c.resultPins)
            if !c.resultPins.isEmpty {
                var anns: [MKAnnotation] = c.resultPins
                if v.userLocation.location != nil { anns.append(v.userLocation) }
                v.showAnnotations(anns, animated: true)
            }
        }
        let selId = model.selectedPlace?.id
        if c.selectedId != selId {
            c.selectedId = selId
            if let a = c.selPin { v.removeAnnotation(a); c.selPin = nil }
            if let p = model.selectedPlace, !model.searchResults.contains(where: { $0.id == p.id }) {
                let a = MKPointAnnotation()
                a.coordinate = p.coordinate
                a.title = p.name
                v.addAnnotation(a)
                c.selPin = a
                v.setCenter(p.coordinate, animated: true)
            }
        }
        if c.recenter != model.recenterToken {
            c.recenter = model.recenterToken
            v.setUserTrackingMode(.follow, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let model: AppModel
        weak var mapView: MKMapView?
        var routeVersion = -1
        var recenter = 0
        var selectedId: UUID? = nil
        var destPin: MKPointAnnotation?
        var selPin: MKPointAnnotation?
        var resultPins: [PlacePin] = []
        var resultIds: [UUID] = []

        init(model: AppModel) { self.model = model }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let l = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: l)
                r.strokeColor = UIColor(red: 0.0, green: 0.72, blue: 0.9, alpha: 1)
                r.lineWidth = 6
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if let pin = annotation as? PlacePin, let p = pin.place {
                model.selectedPlace = p
            } else if let feature = annotation as? MKMapFeatureAnnotation {
                MKMapItemRequest(mapFeatureAnnotation: feature).getMapItem { [weak self] item, _ in
                    guard let self = self, let item = item else { return }
                    DispatchQueue.main.async { self.model.selectMapItem(item) }
                }
                mapView.deselectAnnotation(annotation, animated: false)
            }
        }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let v = mapView else { return }
            let c = v.convert(g.location(in: v), toCoordinateFrom: v)
            model.dropPin(at: c)
        }
    }
}

// MARK: - Hlavní obrazovka
struct MainView: View {
    @EnvironmentObject var m: AppModel
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var phase
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
                PhoneMapView(model: m).ignoresSafeArea()
                VStack(spacing: 10) {
                    topBar
                    if focused {
                        suggestionsList
                    } else if !m.searchResults.isEmpty && m.selectedPlace == nil {
                        resultsList
                    } else if m.destination == nil && m.selectedPlace == nil {
                        favoritesRow
                    }
                    Spacer()
                    if let t = m.toast {
                        Text(t).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    bottomArea
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onReceive(tick) { _ in m.refreshGuidance(); m.refreshNight() }
            .onChange(of: query) { q in m.completer.update(q, near: m.currentLocation) }
            .onChange(of: phase) { p in
                switch p {
                case .background: log("📱 Aplikace na pozadí")
                case .active: log("📱 Aplikace aktivní")
                default: break
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("Where to?"), text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit {
                        // Hledat bez výběru návrhu = všechny výsledky v okolí
                        focused = false
                        m.searchNearby(query)
                    }
                if focused || !query.isEmpty {
                    Button { query = ""; focused = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            NavigationLink { SettingsView() } label: {
                Image(systemName: "gearshape.fill").font(.title3)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }
        }
    }

    private var suggestionsList: some View {
        let items = m.completer.suggestions(query: query, store: m.places)
        return VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text(query.isEmpty ? T("No search history yet") : T("Searching…"))
                    .foregroundStyle(.secondary).padding(12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { s in
                        Button { choose(s) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: s)).frame(width: 22).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).foregroundStyle(.primary).lineLimit(1)
                                    if !s.subtitle.isEmpty {
                                        Text(s.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 9).padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .frame(maxHeight: 380)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(TF("Results nearby: %ld", m.searchResults.count)).font(.subheadline.weight(.semibold))
                Spacer()
                Button(T("Close")) { m.clearResults() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(m.searchResults) { p in
                        Button { m.selectedPlace = p } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).foregroundStyle(.primary).lineLimit(1)
                                    Text([p.subtitle, m.distanceText(to: p) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func icon(for s: Suggestion) -> String {
        guard let p = s.place else { return "mappin.circle" }
        switch p.kind {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        case .favorite: return "star.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }

    private func choose(_ s: Suggestion) {
        focused = false
        query = ""
        m.select(s)
    }

    private var favoritesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                favChip(T("Home"), "house.fill", m.places.home)
                favChip(T("Work"), "briefcase.fill", m.places.work)
                ForEach(m.places.others) { p in favChip(p.name, "star.fill", p) }
            }
        }
    }

    private func favChip(_ title: String, _ icon: String, _ p: Place?) -> some View {
        Button {
            if let p = p { m.navigate(to: p) }
            else { m.flash(TF("%@: search for a place and tap Save → %@", title, title)) }
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .opacity(p == nil ? 0.6 : 1)
        }
        .foregroundStyle(.primary)
        .contextMenu {
            if let p = p {
                Button(role: .destructive) { m.removePlace(p) } label: { Label(T("Remove"), systemImage: "trash") }
            }
        }
    }

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if let p = m.selectedPlace {
                PlaceCard(place: p)
            } else if m.destination != nil {
                GuidancePanel()
            }
            HStack {
                Label(m.bikeConnected ? T("Bike connected") : T("Bike not connected"),
                      systemImage: m.bikeConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(m.bikeConnected ? Color.green : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                Spacer()
                Button { m.recenterToken += 1 } label: {
                    Image(systemName: "location.fill").padding(12).background(.regularMaterial, in: Circle())
                }
            }
        }
    }
}

// MARK: - Karta vybraného místa
struct PlaceCard: View {
    @EnvironmentObject var m: AppModel
    let place: Place

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.headline)
                    if !place.subtitle.isEmpty { Text(place.subtitle).font(.subheadline).foregroundStyle(.secondary) }
                    if let d = m.distanceText(to: place) { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { m.selectedPlace = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button { m.navigate(to: place) } label: {
                    Label(m.calculating ? T("Calculating…") : T("Navigate"), systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.calculating)
                Menu {
                    Button { m.setHome(place) } label: { Label(T("Set as Home"), systemImage: "house") }
                    Button { m.setWork(place) } label: { Label(T("Set as Work"), systemImage: "briefcase") }
                    Button { m.addFavorite(place) } label: { Label(T("Add to favorites"), systemImage: "star") }
                } label: {
                    Label(T("Save"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Panel navigace
struct GuidancePanel: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let g = m.guidance {
                HStack(spacing: 12) {
                    Image(systemName: TurnIcon.symbol(g.icon))
                        .font(.system(size: 34, weight: .bold))
                        .frame(width: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.arrived ? T("You have arrived") : distText(g.toNext)).font(.title2.bold())
                        Text(g.road).font(.subheadline).lineLimit(1)
                    }
                    Spacer()
                }
                HStack {
                    Text(TF("%.1f km · %ld min · arrival %02ld:%02ld",
                            g.remaining / 1000, g.minutesLeft, g.etaHour, g.etaMinute))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { m.endNavigation() } label: { Label(T("End"), systemImage: "xmark") }
                        .buttonStyle(.bordered)
                }
            } else {
                HStack {
                    ProgressView()
                    Text(m.calculating ? T("Calculating route…") : T("Waiting for location…"))
                    Spacer()
                    Button(T("End")) { m.endNavigation() }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func distText(_ meters: Double) -> String {
        let (d, u) = formatDistance(meters)
        return u == "m" ? "\(Int(d)) m" : String(format: "%.1f km", d)
    }
}

// MARK: - Nastavení
struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                Picker(selection: $m.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label(T("Language"), systemImage: "globe")
                }
            }
            Section {
                NavigationLink { MapSettingsView() } label: { Label(T("Map on the bike"), systemImage: "map") }
                NavigationLink { MapDataView() } label: { Label(T("Map data"), systemImage: "externaldrive") }
                NavigationLink { NavSettingsView() } label: { Label(T("Navigation"), systemImage: "arrow.triangle.turn.up.right.diamond") }
                NavigationLink { VoiceSettingsView() } label: { Label(T("Voice guidance"), systemImage: "speaker.wave.2") }
                NavigationLink { AssistSettingsView() } label: { Label(T("Rider assistance"), systemImage: "exclamationmark.triangle") }
                NavigationLink { FavoritesSettingsView() } label: { Label(T("Favorite places"), systemImage: "star") }
            }
            Section {
                NavigationLink { BikeView() } label: {
                    HStack {
                        Label(T("Bike"), systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(m.bikeConnected ? T("connected") : T("not connected")).foregroundStyle(.secondary)
                    }
                }
                NavigationLink { DiagnosticsView() } label: { Label(T("Diagnostics"), systemImage: "wrench.and.screwdriver") }
            }
            Section {
                Button(T("Restore factory settings"), role: .destructive) { confirmReset = true }
            } footer: {
                Text("NaviTest \(m.version) · " + T("Map data © OpenStreetMap contributors, OpenFreeMap, © OpenMapTiles"))
            }
        }
        .navigationTitle(T("Settings"))
        .alert(T("Restore factory settings?"), isPresented: $confirmReset) {
            Button(T("Restore"), role: .destructive) { m.factoryReset() }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(T("All settings will be reset and favorite places and search history will be deleted. Downloaded maps stay on the phone."))
        }
    }
}

struct MapSettingsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section {
                Picker(T("Base map"), selection: $m.opts.mapSource) {
                    ForEach(MapSource.allCases) { Text($0.label).tag($0) }
                }
                Picker(T("View"), selection: $m.opts.threeD) {
                    Text("2D").tag(false)
                    Text("3D").tag(true)
                }.pickerStyle(.segmented)
                Toggle(T("Street names"), isOn: $m.opts.streetNames)
                Toggle(T("Turn arrow and distance in the image"), isOn: $m.opts.turnBox)
                Toggle(T("North up (otherwise direction of travel)"), isOn: $m.opts.northUp)
                Picker(T("Day / night"), selection: $m.opts.dayNight) {
                    ForEach(DayNightMode.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(T("3D: the map is tilted so you see further ahead. Apple map works only with the phone unlocked and only in 2D; the OSM map works in your pocket too. If the dashboard shows the turn arrow in its left column, you can turn off the arrow in the image."))
            }
            Section(T("Image")) {
                Stepper(TF("Frames per second: %ld", Int(m.opts.imageFps)), value: $m.opts.imageFps, in: 1...20, step: 1)
                if m.opts.imageFps > 6 {
                    Text(T("Higher frame rates may make the image transfer unstable."))
                        .font(.caption).foregroundStyle(.red)
                }
                VStack(alignment: .leading) {
                    Text(TF("Image quality: %ld %%", Int(m.opts.jpegQuality * 100)))
                    Slider(value: $m.opts.jpegQuality, in: 0.2...0.9, step: 0.05)
                }
            }
        }
        .navigationTitle(T("Map on the bike"))
    }
}

struct MapDataView: View {
    @EnvironmentObject var m: AppModel
    @State private var url = ""
    @State private var usage = "…"
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                TextField(T("Custom URL (empty = OpenFreeMap)"), text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button(T("Apply")) { m.opts.tileURL = url.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines) == m.opts.tileURL)
            } header: {
                Text(T("Map data source"))
            } footer: {
                Text(T("Vector tiles in the OpenMapTiles schema only: a {z}/{x}/{y} template or a TileJSON address."))
            }
            Section {
                HStack { Text(T("Stored maps")); Spacer(); Text(usage).foregroundStyle(.secondary) }
                Button(T("Delete stored maps"), role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle(T("Map data"))
        .onAppear {
            url = m.opts.tileURL
            refreshUsage()
        }
        .alert(T("Delete stored maps?"), isPresented: $confirmClear) {
            Button(T("Delete"), role: .destructive) {
                TileStore.shared.clearDisk()
                refreshUsage()
            }
            Button(T("Cancel"), role: .cancel) {}
        }
    }

    private func refreshUsage() {
        DispatchQueue.global(qos: .utility).async {
            let b = TileStore.shared.diskUsage()
            let text = ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
            DispatchQueue.main.async { usage = text }
        }
    }
}

struct NavSettingsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section {
                Toggle(T("Avoid motorways"), isOn: $m.avoidHighways)
                Toggle(T("Avoid tolls"), isOn: $m.avoidTolls)
            } footer: {
                Text(T("Motorcycle-friendly routes are planned for a later version."))
            }
        }
        .navigationTitle(T("Navigation"))
    }
}

struct VoiceSettingsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section {
                Toggle(T("Spoken instructions"), isOn: $m.voiceSettings.enabled)
                Toggle(T("Street names in instructions"), isOn: $m.voiceSettings.streetNames)
                    .disabled(!m.voiceSettings.enabled)
                VStack(alignment: .leading) {
                    Text(T("Volume"))
                    Slider(value: $m.voiceSettings.volume, in: 0.2...1.0, step: 0.1)
                }
                .disabled(!m.voiceSettings.enabled)
                Picker(T("Instruction frequency"), selection: $m.voiceSettings.frequency) {
                    ForEach(VoiceFrequency.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!m.voiceSettings.enabled)
                Button(T("Play sample")) { m.voice.sample() }
            }
            Section {
                Picker(T("Voice language"), selection: $m.voiceSettings.language) {
                    ForEach(VoiceLanguage.allCases) { Text($0.label).tag($0) }
                }
                Picker(T("Voice"), selection: $m.voiceSettings.voiceId) {
                    Text(T("Automatic (best available)")).tag("")
                    ForEach(VoiceGuide.voices(for: m.voiceSettings.effectiveLanguage), id: \.identifier) { v in
                        Text(VoiceGuide.describe(v)).tag(v.identifier)
                    }
                }
                VStack(alignment: .leading) {
                    Text(TF("Speech rate: %ld %%", Int((m.voiceSettings.rate * 100).rounded())))
                    Slider(value: $m.voiceSettings.rate, in: 0.6...1.6, step: 0.05)
                }
            } header: {
                Text(T("Voice"))
            } footer: {
                Text(T("Better voices can be downloaded in iPhone Settings → Accessibility → Spoken Content → Voices."))
            }
            Section {
                Picker(T("Output"), selection: $m.voiceSettings.output) {
                    ForEach(AudioOutput.allCases) { Text($0.label).tag($0) }
                }
                Picker(T("Playback mode"), selection: $m.voiceSettings.mode) {
                    ForEach(AudioMode.allCases) { Text($0.label).tag($0) }
                }
                .disabled(m.voiceSettings.output == .speaker)
            } header: {
                Text(T("Audio"))
            } footer: {
                Text(T("As media: better sound, music is only lowered. As phone call: for intercoms that play navigation only as a call; music pauses."))
            }
        }
        .navigationTitle(T("Voice guidance"))
    }
}

struct AssistSettingsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section {
                Toggle(T("Speed cameras and section control"), isOn: $m.assist.cameras)
                Toggle(T("School zones"), isOn: $m.assist.schools)
                Toggle(T("Country borders"), isOn: $m.assist.borders)
                Toggle(T("Speeding"), isOn: $m.assist.speeding)
            } footer: {
                Text(T("Speed camera and speed limit data will be added in a later version. You can try the warnings below."))
            }
            Section(T("Try on the dashboard")) {
                HStack {
                    Button(T("Camera 50")) { m.testWarning(0) }.buttonStyle(.bordered)
                    Button(T("Section 90")) { m.testWarning(1) }.buttonStyle(.bordered)
                    Button(T("Red light")) { m.testWarning(2) }.buttonStyle(.bordered)
                }
                HStack {
                    Button(T("Mobile")) { m.testWarning(3) }.buttonStyle(.bordered)
                    Button(T("School")) { m.testWarning(4) }.buttonStyle(.bordered)
                    Button(T("Border")) { m.testWarning(5) }.buttonStyle(.bordered)
                }
                HStack {
                    Button(T("Speed")) { m.testWarning(6) }.buttonStyle(.bordered)
                    Button(T("Clear all"), role: .destructive) { m.testWarning(9) }.buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle(T("Rider assistance"))
    }
}

struct FavoritesSettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var confirmHistory = false

    var body: some View {
        List {
            Section {
                placeRow(T("Home"), "house.fill", m.places.home)
                placeRow(T("Work"), "briefcase.fill", m.places.work)
            } footer: {
                Text(T("Home and Work can also be chosen from the bike's menu. Set them by searching for a place → Save."))
            }
            Section(T("Favorite places")) {
                if m.places.others.isEmpty { Text(T("None yet")).foregroundStyle(.secondary) }
                ForEach(m.places.others) { p in
                    VStack(alignment: .leading) {
                        Text(p.name)
                        if !p.subtitle.isEmpty { Text(p.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .onDelete { idx in
                    let items = idx.map { m.places.others[$0] }
                    items.forEach { m.removePlace($0) }
                }
            }
            Section {
                Button(TF("Clear search history (%ld)", m.places.history.count), role: .destructive) { confirmHistory = true }
                    .disabled(m.places.history.isEmpty)
            }
        }
        .navigationTitle(T("Favorite places"))
        .alert(T("Clear search history?"), isPresented: $confirmHistory) {
            Button(T("Clear"), role: .destructive) { m.clearHistory() }
            Button(T("Cancel"), role: .cancel) {}
        }
    }

    private func placeRow(_ title: String, _ icon: String, _ p: Place?) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if let p = p {
                Text(p.subtitle.isEmpty ? p.name : p.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button(role: .destructive) { m.removePlace(p) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            } else {
                Text(T("not set")).foregroundStyle(.secondary)
            }
        }
    }
}

struct BikeView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        List {
            Section(T("Status")) {
                row(T("Connection"), T(m.status.phase))
                row(T("Dashboard"), m.status.partNumber)
                row("Model", m.status.model.rawValue)
                row(T("Mode"), m.status.mode.rawValue)
                row(T("Image"), String(format: "%.1f fps · %ld kB", m.status.fps, m.status.lastKB))
                row("Zoom", m.status.zoomText)
            }
            Section {
                HStack {
                    Button(T("Connect")) { m.session.start() }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button(T("Disconnect"), role: .destructive) { m.session.stop() }.buttonStyle(.bordered)
                }
                Toggle(T("Connect to the bike automatically"), isOn: $m.autoConnect)
            }
            Section(T("Accessories (MFi)")) {
                if m.accessories.isEmpty { Text(T("none")).foregroundStyle(.secondary) }
                ForEach(m.accessories, id: \.self) { Text($0).font(.caption) }
                Button(T("Refresh")) { m.refreshAccessories() }
            }
        }
        .navigationTitle(T("Bike"))
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var logs = Log.shared

    var body: some View {
        List {
            Section(T("Navigation source")) {
                Picker(T("Source"), selection: $m.opts.navSource) {
                    ForEach(NavSource.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Toggle(T("Send images"), isOn: $m.opts.sendImages)
                Toggle(T("Send navigation data"), isOn: $m.opts.sendNavData)
                Picker(T("Turn message"), selection: $m.opts.navService) {
                    ForEach(NavServiceChoice.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section(T("Status")) {
                row(T("Map"), m.status.mapStats.isEmpty ? "–" : m.status.mapStats)
                row("GPS", m.gpsText)
                row(T("Last received"), m.status.lastRx)
                row("Self-test", m.selfTestSummary)
            }
            Section {
                Toggle(T("Save log"), isOn: $logs.enabled)
                NavigationLink { LogView() } label: { Label(T("Open log"), systemImage: "doc.text") }
                NavigationLink { StepsView() } label: { Label(T("Show navigation steps"), systemImage: "list.number") }
            } header: {
                Text(T("Log"))
            } footer: {
                Text(T("Turn on before a test ride, then export the log and send it."))
            }
        }
        .navigationTitle(T("Diagnostics"))
    }
}

struct LogView: View {
    @ObservedObject var logs = Log.shared
    var body: some View {
        List {
            ForEach(Array(logs.lines.enumerated().reversed()), id: \.offset) { item in
                Text(item.element).font(.system(size: 11, design: .monospaced))
            }
        }
        .navigationTitle(T("Log"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: logs.exportText()) { Label(T("Export"), systemImage: "square.and.arrow.up") }
            }
        }
    }
}

struct StepsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        List {
            if m.routeSteps.isEmpty {
                Text(T("No route")).foregroundStyle(.secondary)
            } else {
                Section(m.routeSummary) {
                    ForEach(Array(m.routeSteps.enumerated()), id: \.offset) { s in Text(s.element).font(.caption) }
                }
            }
        }
        .navigationTitle(T("Navigation steps"))
    }
}

private func row(_ k: String, _ v: String) -> some View {
    HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
}

import SwiftUI
import MapKit

// MARK: - Mapa v telefonu (Apple mapa – telefon se na ni díváš jen odemčený)
struct PhoneMapView: UIViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let v = MKMapView()
        v.delegate = context.coordinator
        v.showsUserLocation = true
        v.userTrackingMode = .follow
        v.showsCompass = true
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
        let selId = model.selectedPlace?.id
        if c.selectedId != selId {
            c.selectedId = selId
            if let a = c.selPin { v.removeAnnotation(a); c.selPin = nil }
            if let p = model.selectedPlace {
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
        var routeVersion = -1
        var recenter = 0
        var selectedId: UUID? = nil
        var destPin: MKPointAnnotation?
        var selPin: MKPointAnnotation?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let l = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: l)
                r.strokeColor = UIColor(red: 0.0, green: 0.72, blue: 0.9, alpha: 1)
                r.lineWidth = 6
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
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
            .onReceive(tick) { _ in m.refreshGuidance() }
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
                TextField("Kam jedeme?", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit {
                        if let first = m.completer.suggestions(query: query, store: m.places).first { choose(first) }
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
                Text(query.isEmpty ? "Zatím žádná historie hledání" : "Hledám…")
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
                favChip("Domů", "house.fill", m.places.home)
                favChip("Práce", "briefcase.fill", m.places.work)
                ForEach(m.places.others) { p in favChip(p.name, "star.fill", p) }
            }
        }
    }

    private func favChip(_ title: String, _ icon: String, _ p: Place?) -> some View {
        Button {
            if let p = p { m.navigate(to: p) }
            else { m.flash("\(title): vyhledej místo a dej Uložit → \(title)") }
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
                Button(role: .destructive) { m.removePlace(p) } label: { Label("Odstranit", systemImage: "trash") }
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
                Label(m.bikeConnected ? "Motorka připojena" : "Motorka nepřipojena",
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
                    Label(m.calculating ? "Počítám…" : "Navigovat", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.calculating)
                Menu {
                    Button { m.setHome(place) } label: { Label("Nastavit jako Domů", systemImage: "house") }
                    Button { m.setWork(place) } label: { Label("Nastavit jako Práce", systemImage: "briefcase") }
                    Button { m.addFavorite(place) } label: { Label("Přidat do oblíbených", systemImage: "star") }
                } label: {
                    Label("Uložit", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
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
                        Text(g.arrived ? "Jste v cíli" : distText(g.toNext)).font(.title2.bold())
                        Text(g.road).font(.subheadline).lineLimit(1)
                    }
                    Spacer()
                }
                HStack {
                    Text(String(format: "%.1f km · %ld min · příjezd %02ld:%02ld",
                                g.remaining / 1000, g.minutesLeft, g.etaHour, g.etaMinute))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { m.endNavigation() } label: { Label("Ukončit", systemImage: "xmark") }
                        .buttonStyle(.bordered)
                }
            } else {
                HStack {
                    ProgressView()
                    Text(m.calculating ? "Počítám trasu…" : "Čekám na polohu…")
                    Spacer()
                    Button("Ukončit") { m.endNavigation() }
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
                NavigationLink { MapSettingsView() } label: { Label("Mapa v motorce", systemImage: "map") }
                NavigationLink { NavSettingsView() } label: { Label("Navigace", systemImage: "arrow.triangle.turn.up.right.diamond") }
                NavigationLink { AssistSettingsView() } label: { Label("Asistence jezdce", systemImage: "exclamationmark.triangle") }
                NavigationLink { FavoritesSettingsView() } label: { Label("Oblíbená místa", systemImage: "star") }
            }
            Section {
                NavigationLink { BikeView() } label: {
                    HStack {
                        Label("Motorka", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(m.bikeConnected ? "připojena" : "nepřipojena").foregroundStyle(.secondary)
                    }
                }
                NavigationLink { DiagnosticsView() } label: { Label("Diagnostika", systemImage: "wrench.and.screwdriver") }
            }
            Section {
                Button("Obnovit tovární nastavení", role: .destructive) { confirmReset = true }
            } footer: {
                Text("NaviTest \(m.version) · Mapová data © přispěvatelé OpenStreetMap, OpenFreeMap, © OpenMapTiles")
            }
        }
        .navigationTitle("Nastavení")
        .alert("Obnovit tovární nastavení?", isPresented: $confirmReset) {
            Button("Obnovit", role: .destructive) { m.factoryReset() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Vrátí se všechna nastavení a smažou se oblíbená místa i historie hledání. Stažené mapy v telefonu zůstanou.")
        }
    }
}

struct MapSettingsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section {
                Picker("Podklad", selection: $m.opts.mapSource) {
                    ForEach(MapSource.allCases) { Text($0.label).tag($0) }
                }
                Picker("Pohled", selection: $m.opts.threeD) {
                    Text("2D").tag(false)
                    Text("3D").tag(true)
                }.pickerStyle(.segmented)
                Toggle("Názvy ulic", isOn: $m.opts.streetNames)
                Toggle("Šipka a vzdálenost v obrázku", isOn: $m.opts.turnBox)
                Toggle("Sever nahoře (jinak po směru jízdy)", isOn: $m.opts.northUp)
                Toggle("Tmavá mapa", isOn: $m.opts.darkMap)
            } footer: {
                Text("3D: mapa je nakloněná, vidíš dál dopředu. Apple mapa funguje jen s odemčeným telefonem a jen ve 2D; mapa OSM funguje i v kapse. Pokud přístrojovka ukazuje šipku v levém sloupci, šipku v obrázku můžeš vypnout.")
            }
            Section("Obraz") {
                Stepper("Snímků za sekundu: \(Int(m.opts.imageFps))", value: $m.opts.imageFps, in: 1...6, step: 1)
                VStack(alignment: .leading) {
                    Text("Kvalita obrazu: \(Int(m.opts.jpegQuality * 100)) %")
                    Slider(value: $m.opts.jpegQuality, in: 0.2...0.9, step: 0.05)
                }
            }
        }
        .navigationTitle("Mapa v motorce")
    }
}

struct NavSettingsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section {
                Toggle("Vyhnout se dálnicím", isOn: $m.avoidHighways)
                Toggle("Vyhnout se placeným úsekům", isOn: $m.avoidTolls)
            } footer: {
                Text("Motorkářské trasy a hlasové pokyny do helmy připravujeme.")
            }
        }
        .navigationTitle("Navigace")
    }
}

struct AssistSettingsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section {
                Toggle("Radary a úsekové měření", isOn: $m.assist.cameras)
                Toggle("Školní zóny", isOn: $m.assist.schools)
                Toggle("Hranice států", isOn: $m.assist.borders)
                Toggle("Překročení rychlosti", isOn: $m.assist.speeding)
            } footer: {
                Text("Data o radarech a rychlostních limitech doplníme v další verzi. Zatím si můžeš varování vyzkoušet níže.")
            }
            Section("Vyzkoušet na přístrojovce") {
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
        .navigationTitle("Asistence jezdce")
    }
}

struct FavoritesSettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var confirmHistory = false

    var body: some View {
        List {
            Section {
                placeRow("Domů", "house.fill", m.places.home)
                placeRow("Práce", "briefcase.fill", m.places.work)
            } footer: {
                Text("Domů a Práce se dají vybrat i v menu motorky. Nastavíš je přes vyhledání místa → Uložit.")
            }
            Section("Oblíbená místa") {
                if m.places.others.isEmpty { Text("Zatím žádná").foregroundStyle(.secondary) }
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
                Button("Smazat historii hledání (\(m.places.history.count))", role: .destructive) { confirmHistory = true }
                    .disabled(m.places.history.isEmpty)
            }
        }
        .navigationTitle("Oblíbená místa")
        .alert("Smazat historii hledání?", isPresented: $confirmHistory) {
            Button("Smazat", role: .destructive) { m.clearHistory() }
            Button("Zrušit", role: .cancel) {}
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
                Text("nenastaveno").foregroundStyle(.secondary)
            }
        }
    }
}

struct BikeView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        List {
            Section("Stav") {
                row("Spojení", m.status.phase)
                row("Přístrojovka", m.status.partNumber)
                row("Model", m.status.model.rawValue)
                row("Režim", m.status.mode.rawValue)
                row("Obraz", String(format: "%.1f fps · %ld kB", m.status.fps, m.status.lastKB))
                row("Zoom", m.status.zoomText)
            }
            Section {
                HStack {
                    Button("Připojit") { m.session.start() }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Odpojit", role: .destructive) { m.session.stop() }.buttonStyle(.bordered)
                }
                Toggle("Automaticky připojit k motorce", isOn: $m.autoConnect)
            }
            Section("Příslušenství (MFi)") {
                if m.accessories.isEmpty { Text("žádné").foregroundStyle(.secondary) }
                ForEach(m.accessories, id: \.self) { Text($0).font(.caption) }
                Button("Obnovit") { m.refreshAccessories() }
            }
        }
        .navigationTitle("Motorka")
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var logs = Log.shared

    var body: some View {
        List {
            Section("Zdroj navigace") {
                Picker("Zdroj", selection: $m.opts.navSource) {
                    ForEach(NavSource.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("Posílat obrázky", isOn: $m.opts.sendImages)
                Toggle("Posílat navigační data", isOn: $m.opts.sendNavData)
                Picker("Zpráva se šipkami", selection: $m.opts.navService) {
                    ForEach(NavServiceChoice.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section("Stav") {
                row("Mapa", m.status.mapStats.isEmpty ? "–" : m.status.mapStats)
                row("GPS", m.gpsText)
                row("Poslední příchozí", m.status.lastRx)
                row("Self-test", m.selfTestSummary)
            }
            if !m.routeSteps.isEmpty {
                Section(m.routeSummary) {
                    ForEach(Array(m.routeSteps.enumerated()), id: \.offset) { s in Text(s.element).font(.caption) }
                }
            }
            Section("Log") {
                ShareLink(item: Log.shared.fileURL) { Label("Exportovat celý log", systemImage: "square.and.arrow.up") }
                ForEach(Array(logs.lines.enumerated().reversed()), id: \.offset) { item in
                    Text(item.element).font(.system(size: 11, design: .monospaced))
                }
            }
        }
        .navigationTitle("Diagnostika")
    }
}

private func row(_ k: String, _ v: String) -> some View {
    HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
}

import SwiftUI
import UIKit
import CoreLocation
import ExternalAccessory

// MARK: - Udržení běhu na pozadí (stejný mechanismus jako každá navigace: GPS na pozadí)
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    private let lm = CLLocationManager()
    private(set) var active = false

    func start() {
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.pausesLocationUpdatesAutomatically = false
        lm.activityType = .automotiveNavigation
        lm.allowsBackgroundLocationUpdates = true
        lm.showsBackgroundLocationIndicator = true
        if lm.authorizationStatus == .notDetermined { lm.requestWhenInUseAuthorization() }
        lm.startUpdatingLocation()
        active = true
        log("GPS keep-alive zapnut (oprávnění: \(lm.authorizationStatus.rawValue))")
    }

    func stop() {
        lm.stopUpdatingLocation()
        active = false
        log("GPS keep-alive vypnut")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        log("Oprávnění k poloze: \(manager.authorizationStatus.rawValue) (4 = při používání, 3 = vždy)")
        if active { manager.startUpdatingLocation() }
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
    @Published var keepAlive = true { didSet { keepAlive ? ka.start() : ka.stop() } }

    let session = DashSession()
    private let ka = KeepAlive()

    init() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        log("NaviTest \(v) spuštěn, iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
        session.options = opts
        session.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }

        let t = NL.selfTest()
        selfTestSummary = "\(t.passed)/\(t.total) \(t.passed == t.total ? "OK" : "CHYBA")"
        log("Self-test protokolu: \(selfTestSummary)")
        t.lines.forEach { log("   \($0)") }

        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(forName: .EAAccessoryDidConnect, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[EAAccessoryKey] as? EAAccessory { log("🔌 Připojeno příslušenství: \(DashLink.describe(a))") }
            self?.refreshAccessories()
            if self?.autoConnect == true, self?.session.isRunning == false,
               let a = n.userInfo?[EAAccessoryKey] as? EAAccessory, a.protocolStrings.contains(DashLink.proto) {
                log("Auto-připojení…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.session.start() }
            }
        }
        NotificationCenter.default.addObserver(forName: .EAAccessoryDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[EAAccessoryKey] as? EAAccessory { log("🔌 Odpojeno příslušenství: \(a.name)") }
            self?.refreshAccessories()
        }
        refreshAccessories()
        ka.start()

        if autoConnect, DashLink.findAccessory() != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.session.start() }
        }
    }

    func refreshAccessories() {
        let accs = EAAccessoryManager.shared().connectedAccessories
        accessories = accs.map { DashLink.describe($0) }
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
                Section("Stav") {
                    row("Spojení", m.status.phase)
                    row("Přístrojovka", m.status.partNumber)
                    row("Model", m.status.model.rawValue)
                    row("Režim (dle motorky)", m.status.mode.rawValue)
                    row("Obrázky", String(format: "%.1f fps · %ld kB · potvrzeno %ld", m.status.fps, m.status.lastKB, m.status.imagesAcked))
                    row("Nav. zprávy odeslány", "\(m.status.navSent)")
                    row("Poslední příchozí", m.status.lastRx)
                    row("Self-test protokolu", m.selfTestSummary)
                }
                Section("Ovládání") {
                    HStack {
                        Button("Připojit") { m.session.start() }.buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Odpojit", role: .destructive) { m.session.stop() }.buttonStyle(.bordered)
                    }
                    Toggle("Auto-připojení k motorce", isOn: $m.autoConnect)
                    Toggle("Běh na pozadí (GPS)", isOn: $m.keepAlive)
                }
                Section("Co posílat") {
                    Toggle("Obrázky mapy (režim MAPA)", isOn: $m.opts.sendImages)
                    Toggle("Navigační data (šipky, vzdálenost)", isOn: $m.opts.sendNavData)
                    Picker("Navigační služba", selection: $m.opts.navService) {
                        ForEach(NavServiceChoice.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                    Stepper("Obrázky: \(Int(m.opts.imageFps)) fps", value: $m.opts.imageFps, in: 1...10, step: 1)
                    VStack(alignment: .leading) {
                        Text("Kvalita JPEG: \(Int(m.opts.jpegQuality * 100)) %")
                        Slider(value: $m.opts.jpegQuality, in: 0.2...0.9, step: 0.05)
                    }
                }
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

import Foundation
import ExternalAccessory
import CoreLocation
import MapKit

/// Místo nabízené v seznamu oblíbených na přístrojovce.
struct BikeFav {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let tag: String          // "home", "work", id oblíbeného…
}

enum NavServiceChoice: String, CaseIterable, Identifiable, Codable {
    case auto, svc19, svc4, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .svc19: return "19"
        case .svc4: return "4"
        case .both: return "Obě"
        }
    }
}

enum NavSource: String, CaseIterable, Identifiable, Codable {
    case sim, real
    var id: String { rawValue }
    var label: String { self == .sim ? "Simulace" : "Skutečná" }
}

struct TestOptions: Codable {
    var sendImages = true
    var sendNavData = true
    var navService: NavServiceChoice = .auto
    var imageFps: Double = 3
    var jpegQuality: Double = 0.55
    var navSource: NavSource = .real
    var mapSource: MapSource = .vector
    var turnBox = true                // vlastní šipka + vzdálenost v obrázku
    var northUp = false
    var darkMap = true
    var threeD = false                // 3D (nakloněný) pohled
    var streetNames = true            // názvy ulic podél silnic

    init() {}

    // Tolerantní načítání: chybějící položka (nová ve verzi appky) = výchozí hodnota
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TestOptions()
        sendImages = (try? c.decodeIfPresent(Bool.self, forKey: .sendImages)) ?? d.sendImages
        sendNavData = (try? c.decodeIfPresent(Bool.self, forKey: .sendNavData)) ?? d.sendNavData
        navService = (try? c.decodeIfPresent(NavServiceChoice.self, forKey: .navService)) ?? d.navService
        imageFps = (try? c.decodeIfPresent(Double.self, forKey: .imageFps)) ?? d.imageFps
        jpegQuality = (try? c.decodeIfPresent(Double.self, forKey: .jpegQuality)) ?? d.jpegQuality
        navSource = (try? c.decodeIfPresent(NavSource.self, forKey: .navSource)) ?? d.navSource
        mapSource = (try? c.decodeIfPresent(MapSource.self, forKey: .mapSource)) ?? d.mapSource
        turnBox = (try? c.decodeIfPresent(Bool.self, forKey: .turnBox)) ?? d.turnBox
        northUp = (try? c.decodeIfPresent(Bool.self, forKey: .northUp)) ?? d.northUp
        darkMap = (try? c.decodeIfPresent(Bool.self, forKey: .darkMap)) ?? d.darkMap
        threeD = (try? c.decodeIfPresent(Bool.self, forKey: .threeD)) ?? d.threeD
        streetNames = (try? c.decodeIfPresent(Bool.self, forKey: .streetNames)) ?? d.streetNames
    }
}

enum ContentMode: String {
    case none = "žádný"
    case map = "MAPA (obrázky)"
    case tbt = "TURN-BY-TURN"
}

enum DashModel: String {
    case unknown = "neznámý"
    case ixww22 = "IXWW22 (služba 4)"
    case imww23 = "IMWW23 (služba 19)"
}

struct SessionStatus {
    var phase = "Nepřipojeno"
    var partNumber = "–"
    var model: DashModel = .unknown
    var mode: ContentMode = .none
    var imagesAcked = 0
    var fps = 0.0
    var lastKB = 0
    var navSent = 0
    var lastRx = "–"
    var zoomText = ""
    var mapStats = ""
}

final class DashSession {
    private let link = DashLink()
    private let sim = RouteSimulator()
    private let renderer = FrameRenderer()
    let navigator: Navigator
    let snapshots: MapSnapshotProvider

    private let lock = NSLock()
    private var _opts = TestOptions()
    private var _running = false
    private var pending: [NLMessage] = []

    var options: TestOptions {
        get { lock.lock(); defer { lock.unlock() }; return _opts }
        set { lock.lock(); _opts = newValue; lock.unlock() }
    }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    private func setRunning(_ v: Bool) { lock.lock(); _running = v; lock.unlock() }

    var onStatus: ((SessionStatus) -> Void)?
    /// Příkazy z joysticku / přístrojovky (49 stop trasy, 53 domů, …) – volá se na hlavním vlákně.
    var onBikeCommand: ((UInt8) -> Void)?
    /// Jezdec vybral cíl ze seznamu oblíbených na přístrojovce – volá se na hlavním vlákně.
    var onBikeNavigate: ((BikeFav) -> Void)?

    // Oblíbená místa pro přístrojovku (chráněno zámkem)
    private var bikeFavs: [BikeFav] = []
    private var homeSet = false
    private var officeSet = false
    // Seznam, který motorka právě zobrazuje (jen pracovní vlákno)
    private var favListIndex = 1
    private var favsSent: [BikeFav] = []

    // Stav, se kterým pracuje jen pracovní vlákno
    private var status = SessionStatus()
    private var mode: ContentMode = .none
    private var model: DashModel = .unknown
    static let defaultZoom = 7          // 4,5 m/px
    private var zoomLevel: Int = {
        let z = UserDefaults.standard.object(forKey: "zoomLevel") as? Int ?? DashSession.defaultZoom
        return min(16, max(0, z))
    }()
    private var pendingZoomReset = false
    private var seq = 1
    private var lastTbtIndex = -1
    private var lastSpeedLog = Date.distantPast
    private var lastGuiding: Bool? = nil
    private var lastLoggedSource: MapSource? = nil
    private var lastRouteGen = -1

    /// metrů na pixel pro jednotlivé úrovně zoomu (0,25 = nejblíž, 160 = nejdál)
    private let mppTable: [Double] = [0.25, 0.4, 0.6, 0.9, 1.3, 2, 3, 4.5, 6.5, 10, 15, 22, 33, 50, 75, 110, 160]

    init(navigator: Navigator, snapshots: MapSnapshotProvider) {
        self.navigator = navigator
        self.snapshots = snapshots
    }

    // MARK: Veřejné ovládání (z hlavního vlákna)
    func start() {
        guard !isRunning else { log("Session už běží"); return }
        let accs = EAAccessoryManager.shared().connectedAccessories
        log("Připojená příslušenství: \(accs.count)")
        for a in accs { log("  • \(DashLink.describe(a))") }
        guard let acc = DashLink.findAccessory() else {
            log("❌ Žádné příslušenství s protokolem \(DashLink.proto). Zapalování, Bluetooth a navigace na přístrojovce?")
            publish(phase: "Motorka nenalezena")
            return
        }
        setRunning(true)
        let t = Thread { [weak self] in self?.run(acc) }
        t.name = "dash-session"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() {
        guard isRunning else { return }
        log("Zastavuji session…")
        setRunning(false)
        link.close()
    }

    /// Aktualizace oblíbených míst a příznaků Domů/Práce (z hlavního vlákna).
    func setBikeFavorites(_ favs: [BikeFav], home: Bool, office: Bool) {
        lock.lock()
        let changedHome = home != homeSet, changedOffice = office != officeSet
        bikeFavs = Array(favs.prefix(50))
        homeSet = home
        officeSet = office
        if _running {
            if changedHome { pending.append(NL.flag(10, home)) }
            if changedOffice { pending.append(NL.flag(11, office)) }
        }
        lock.unlock()
    }

    /// Tovární reset zoomu (provede pracovní vlákno).
    func resetZoom() { lock.lock(); pendingZoomReset = true; lock.unlock() }

    /// Pošle zprávy při nejbližší příležitosti (varování apod.).
    func enqueue(_ msgs: [NLMessage]) {
        lock.lock(); pending += msgs; lock.unlock()
    }

    // MARK: Hlavní běh
    private func run(_ acc: EAAccessory) {
        status = SessionStatus()
        mode = .none
        model = .unknown
        lastTbtIndex = -1
        lastGuiding = nil
        lastLoggedSource = nil
        lastRouteGen = -1
        defer {
            link.close()
            setRunning(false)
            mode = .none
            publish(phase: "Odpojeno")
            log("Session ukončena")
        }
        do {
            try link.open(acc)
            log("✅ EASession otevřena (\(acc.name))")
        } catch {
            log("❌ \(error.localizedDescription)")
            return
        }
        publish(phase: "Handshake…")
        guard handshake() else { return }
        mode = .map
        publish(phase: "Spojeno")
        loop()
    }

    private func handshake() -> Bool {
        log("Čekám na ESN (služba 66)…")
        guard let esn = waitFor(66, timeout: 15) else { log("❌ ESN nepřišlo do 15 s"); return false }
        log("⬅️ ESN: \(String(decoding: esn.payload, as: UTF8.self))")
        send(NL.esnAck())
        send(NL.authRequest())
        guard let sec = waitFor(83, timeout: 10) else { log("❌ SEC_DATA nepřišlo"); return false }
        let part = NL.partNumber(seed: sec.payload)
        if part.contains("006-B3952") { model = .ixww22 }
        else if part.contains("006-B4160") || part.contains("006-B4920") { model = .imww23 }
        status.partNumber = part
        status.model = model
        log("⬅️ Číslo dílu přístrojovky: \(part) → model \(model.rawValue)")
        guard let ack = NL.secDataAck(seed: sec.payload) else { log("❌ Vadné SEC_DATA"); return false }
        send(ack)
        send(NL.flag(2, false))
        send(NL.dayNight(1))
        lock.lock(); let h = homeSet, w = officeSet; lock.unlock()
        send(NL.flag(10, h))                       // je nastaven Domov
        send(NL.flag(11, w))                       // je nastavena Práce
        send(NL.flag(13, true))
        send(NL.flag(12, false))
        send(zoomMessage(show: false))
        send(NL.currentRoad(""))
        send(NL.speedLimit(0, unit: "km/h"))
        send(NL.flag(13, true))
        send(NL.flag(12, true))                    // init setup complete
        log("✅ Autentizace + nastavení odesláno")
        return true
    }

    private func loop() {
        var lastNav = Date()
        var lastImage = Date.distantPast
        var awaitingAck = false
        var ackSentAt = Date()
        var ackTimeouts = 0
        var acksInWindow = 0
        var windowStart = Date()
        var lastSummary = Date()
        var nav: NavSnapshot? = nil

        while isRunning && link.isOpen {
            // 1) Příchozí zprávy
            var got = 0
            while got < 30, let f = link.readFrame(timeout: got == 0 ? 0.02 : 0) {
                got += 1
                if f.svc == 80 {
                    if awaitingAck {
                        awaitingAck = false
                        ackTimeouts = 0
                        acksInWindow += 1
                        status.imagesAcked += 1
                    }
                } else {
                    handle(f)
                }
            }
            // 2) Zprávy z fronty (varování z UI) + případný reset zoomu
            lock.lock()
            let q = pending; pending.removeAll()
            let doReset = pendingZoomReset; pendingZoomReset = false
            lock.unlock()
            if doReset {
                zoomLevel = DashSession.defaultZoom
                UserDefaults.standard.removeObject(forKey: "zoomLevel")
                send(zoomMessage(show: true))
                status.zoomText = zoomLabel()
            }
            for m in q { send(m); log("➡️ \(NL.name(m.svc)) [\(m.payload.hex)]") }

            let now = Date()
            let o = options

            // 3) Navigační data 1× za sekundu
            if now.timeIntervalSince(lastNav) >= 1.0 {
                let dt = now.timeIntervalSince(lastNav)
                lastNav = now
                if o.navSource == .sim {
                    sim.tick(dt)
                    nav = sim.snapshot()
                } else {
                    nav = navigator.snapshot()
                }
                updateGuidingState(nav)
                // Nová trasa (nebo přepočet, nebo nové připojení během navigace) → start trasy jako Garmin
                if let n = nav, n.guiding {
                    let gen = o.navSource == .real ? navigator.routeGeneration : -2   // simulace = jedna „trasa“
                    if gen != lastRouteGen {
                        lastRouteGen = gen
                        sendRouteStart()
                    }
                }
                if o.sendNavData, let n = nav, n.guiding { sendNav(n, o) }
            }

            // 4) Obrázky – jen v režimu mapy, vždy až po ACK předchozího
            if mode == .map && o.sendImages {
                if awaitingAck && now.timeIntervalSince(ackSentAt) > 3 {
                    awaitingAck = false
                    ackTimeouts += 1
                    log("⚠️ IMAGE_ACK nepřišel do 3 s (\(ackTimeouts)× po sobě)")
                }
                if !awaitingAck && now.timeIntervalSince(lastImage) >= 1.0 / max(0.5, o.imageFps) {
                    if o.mapSource != lastLoggedSource {
                        log("🖼️ Podklad mapy: \(o.mapSource.label)")
                        lastLoggedSource = o.mapSource
                    }
                    var p = RenderParams()
                    p.quality = o.jpegQuality
                    p.mpp = mpp()
                    p.northUp = o.northUp
                    p.dark = o.darkMap
                    p.mapSource = o.mapSource
                    p.turnBox = o.turnBox
                    p.threeD = o.threeD
                    p.streetNames = o.streetNames
                    var snap: MapSnapshotProvider.Snap? = nil
                    if o.mapSource == .apple, let pos = nav?.position {
                        snapshots.ensure(center: pos, mpp: p.mpp, dark: o.darkMap)
                        snap = snapshots.latest()
                    }
                    if let jpg = renderer.render(frame: seq, nav: nav, p: p, snap: snap) {
                        // Typ 0 = normální navigace: přístrojovka ukáže obraz bez levého sloupce
                        send(NL.image(seq: seq, jpeg: jpg, imageType: 0))
                        if seq == 1 { log("➡️ První obrázek odeslán (\(jpg.count) B)") }
                        seq = seq >= 0xFFFF ? 1 : seq + 1
                        status.lastKB = jpg.count / 1024
                        awaitingAck = true
                        ackSentAt = now
                        lastImage = now
                    } else {
                        log("❌ Nepodařilo se vykreslit/zakódovat snímek")
                        lastImage = now
                    }
                }
            }

            // 5) Stav do UI
            if now.timeIntervalSince(windowStart) >= 2 {
                status.fps = Double(acksInWindow) / now.timeIntervalSince(windowStart)
                acksInWindow = 0
                windowStart = now
                status.mapStats = o.mapSource == .apple ? snapshots.stats : TileStore.shared.stats
                publish()
            }
            if now.timeIntervalSince(lastSummary) >= 30 {
                lastSummary = now
                let g = nav.map { n in n.guiding ? "\(TurnIcon.name(n.icon)) za \(Int(n.toNext)) m, zbývá \(Int(n.remaining)) m" : "volná jízda" } ?? "bez polohy"
                log(String(format: "ℹ️ %@ · %.1f fps (%ld kB) · potvrzeno %ld · %@", mode.rawValue, status.fps, status.lastKB, status.imagesAcked, g))
            }
        }
        if !link.isOpen { log("Spojení s motorkou zavřeno") }
    }

    private func mpp() -> Double { mppTable[min(mppTable.count - 1, max(0, zoomLevel))] }

    private func zoomLabel() -> String {
        let m = Int(mpp() * 80)   // délka měřítka ~80 px
        return m < 1000 ? "\(m) m" : String(format: "%.1f km", Double(m) / 1000)
    }

    private func zoomMessage(show: Bool) -> NLMessage {
        NL.zoom(current: zoomLevel, lo: 0, hi: mppTable.count - 1, label: zoomLabel(), show: show)
    }

    /// Sekvence jako StreetCross po výpočtu trasy: průběh 0 → 100 % → hotovo, „naviguji“, průjezdní body.
    private func sendRouteStart() {
        send(NL.routeCalcProgress(0))
        send(NL.routeCalcProgress(100))
        send(NL.routeCalcProgress(-1))
        send(NL.flag(2, true))
        send(NL.viaCount(0))
        log("➡️ Start trasy pro přístrojovku (výpočet 0→100 %, hotovo, naviguji, průjezdní body 0)")
    }

    private func updateGuidingState(_ nav: NavSnapshot?) {
        let g = nav?.guiding ?? false
        if lastGuiding != g {
            lastGuiding = g
            send(NL.flag(2, g))
            if !g {
                send(NL.currentRoad(""))
                send(NL.speedLimit(0, unit: "km/h"))
            }
            log(g ? "🧭 Navigace aktivní" : "🧭 Bez trasy (volná jízda)")
        }
    }

    // MARK: Příchozí zprávy
    private func handle(_ f: InFrame) {
        status.lastRx = "\(f.svc) \(NL.name(f.svc))"
        switch f.svc {
        case 55:
            let ct = f.payload.first ?? 0
            log("⬅️ Motorka žádá START obsahu: \(NL.contentName(ct)) [\(f.payload.hex)]")
            if ct == 1 {
                mode = .map
                send(NL.flag(2, lastGuiding ?? false)); send(NL.flag(13, true)); send(NL.flag(12, true))
                send(zoomMessage(show: false))
            } else if ct == 2 {
                mode = .tbt
                lastTbtIndex = -1
            } else if ct == 3 {
                sendFavoritesList()
            }
            publish()
        case 56:
            let ct = f.payload.first ?? 0
            log("⬅️ Motorka žádá STOP obsahu: \(NL.contentName(ct)) [\(f.payload.hex)]")
            if ct == 1 && mode == .map { send(NL.imageStopped()); mode = .none }
            if ct == 2 && mode == .tbt { mode = .none }
            publish()
        case 51, 52:
            zoomLevel = f.svc == 51 ? max(0, zoomLevel - 1) : min(mppTable.count - 1, zoomLevel + 1)
            UserDefaults.standard.set(zoomLevel, forKey: "zoomLevel")
            log("⬅️ Joystick: \(f.svc == 51 ? "ZOOM +" : "ZOOM −") → úroveň \(zoomLevel) (\(zoomLabel()))")
            send(zoomMessage(show: true))
            status.zoomText = zoomLabel()
        case 48:
            // [položka u16][seznam u16][volba trasy u8] – ověřeno Garminovým dekodérem
            log("⬅️ Motorka: start trasy [\(f.payload.hex)]")
            guard f.payload.count >= 4 else { break }
            let item = Int(f.payload[0]) | Int(f.payload[1]) << 8
            let list = Int(f.payload[2]) | Int(f.payload[3]) << 8
            if list == favListIndex && item < favsSent.count {
                let fav = favsSent[item]
                log("🏁 Vybráno na motorce: \(fav.name)")
                let cb = onBikeNavigate
                DispatchQueue.main.async { cb?(fav) }
            } else {
                log("⚠️ Neznámá položka: seznam \(list) (aktuální \(favListIndex)), položka \(item) z \(favsSent.count)")
            }
        case 49, 50, 53, 54:
            log("⬅️ Příkaz z motorky: \(NL.name(f.svc)) [\(f.payload.hex)]")
            let cb = onBikeCommand, svc = f.svc
            DispatchQueue.main.async { cb?(svc) }
        case 65:
            if Date().timeIntervalSince(lastSpeedLog) > 30 {
                lastSpeedLog = Date()
                log("⬅️ Rychlost z motorky: \(f.payload.hex)")
            }
        case 66:
            log("⬅️ ESN znovu: \(String(decoding: f.payload, as: UTF8.self))")
        case 69:
            log("⬅️ SYSINFO: \(String(decoding: f.payload, as: UTF8.self))")
        default:
            let hex = Array(f.payload.prefix(48)).hex
            log("⬅️ \(f.svc) \(NL.name(f.svc)) ft=\(f.frameType) pdt=\(f.pdt) len=\(f.payload.count) [\(hex)]")
        }
    }

    // MARK: Odchozí navigační data
    private func sendNav(_ s: NavSnapshot, _ o: TestOptions) {
        let (d, u) = formatDistance(s.toNext)
        let (rd, ru) = formatDistance(s.remaining)
        let use19: Bool, use4: Bool
        switch o.navService {
        case .svc19: use19 = true; use4 = false
        case .svc4: use19 = false; use4 = true
        case .both: use19 = true; use4 = true
        case .auto:
            switch model {
            case .imww23: use19 = true; use4 = false
            case .ixww22: use19 = false; use4 = true
            case .unknown: use19 = true; use4 = true
            }
        }
        if use19 {
            send(NL.navInfo(icon: s.icon, dist: d, unit: u, road: s.road,
                            remain: rd, remainUnit: ru, minutes: s.minutesLeft, lanes: s.lanes))
        }
        if use4 { send(NL.nextTurn(icon: s.icon, dist: d, unit: u, road: s.road)) }
        send(NL.currentRoad(s.currentRoad))
        send(NL.speedLimit(s.speedLimit, unit: "km/h"))
        send(NL.eta(hour: s.etaHour, minute: s.etaMinute))
        status.navSent += 1

        if mode == .tbt {
            if s.maneuverIndex != lastTbtIndex { sendTbtList(s) }
            else if let first = s.upcoming.first {
                let (dd, uu) = formatDistance(first.dist)
                send(NL.tbtItem(index: 0, icon: first.icon, dist: dd, unit: uu, text: first.text))
            }
        }
    }

    /// Pošle seznam oblíbených míst (Domů, Práce, oblíbené, poslední cíle) se vzdáleností a směrem.
    private func sendFavoritesList() {
        lock.lock(); let favs = bikeFavs; lock.unlock()
        favListIndex = 1 - favListIndex          // jako Garmin: seznamy 0/1 se střídají
        favsSent = favs
        send(NL.favPoiUpdate(count: favs.count))
        let here = navigator.location
        let heading = navigator.snapshot()?.heading ?? max(0, here?.course ?? 0)
        for (i, f) in favs.enumerated() {
            var dir: UInt8 = 1
            var dist: Double = 0
            if let h = here {
                let target = CLLocation(latitude: f.coordinate.latitude, longitude: f.coordinate.longitude)
                dist = h.distance(from: target)
                let b = NavRoute.bearing(MKMapPoint(h.coordinate), MKMapPoint(f.coordinate))
                let rel = (b - heading + 720).truncatingRemainder(dividingBy: 360)
                dir = UInt8((Int((rel / 45).rounded()) % 8) + 1)
            }
            let (d, u) = formatDistance(dist)
            send(NL.favPoiData(list: favListIndex, item: i, direction: dir, dist: d, unit: u, name: f.name))
        }
        log("➡️ Oblíbená místa pro motorku: \(favs.count) (seznam \(favListIndex))")
    }

    private func sendTbtList(_ s: NavSnapshot) {
        lastTbtIndex = s.maneuverIndex
        send(NL.tbtListUpdate(count: s.upcoming.count, hasMore: false))
        for (i, item) in s.upcoming.enumerated() {
            let (d, u) = formatDistance(item.dist)
            send(NL.tbtItem(index: i, icon: item.icon, dist: d, unit: u, text: item.text))
        }
        send(NL.activeTbt(0))
        log("➡️ Turn-by-turn seznam: \(s.upcoming.count) položek")
    }

    // MARK: Pomocné
    private func send(_ m: NLMessage) { link.write(m.frame) }

    private func waitFor(_ svc: UInt8, timeout: TimeInterval) -> InFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && link.isOpen {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            guard let f = link.readFrame(timeout: left) else { continue }
            if f.svc == svc { return f }
            log("⬅️ (během handshaku) \(f.svc) \(NL.name(f.svc)) [\(Array(f.payload.prefix(32)).hex)]")
        }
        return nil
    }

    private func publish(phase: String? = nil) {
        if let p = phase { status.phase = p }
        status.mode = mode
        status.model = model
        if status.zoomText.isEmpty { status.zoomText = zoomLabel() }
        let s = status
        onStatus?(s)
    }
}

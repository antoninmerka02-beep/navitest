import Foundation
import ExternalAccessory

enum NavServiceChoice: String, CaseIterable, Identifiable {
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

struct TestOptions {
    var sendImages = true
    var sendNavData = true
    var navService: NavServiceChoice = .auto
    var imageFps: Double = 3
    var jpegQuality: Double = 0.5
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
}

final class DashSession {
    private let link = DashLink()
    private let sim = RouteSimulator()
    private let renderer = FrameRenderer()

    private let lock = NSLock()
    private var _opts = TestOptions()
    private var _running = false

    var options: TestOptions {
        get { lock.lock(); defer { lock.unlock() }; return _opts }
        set { lock.lock(); _opts = newValue; lock.unlock() }
    }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    private func setRunning(_ v: Bool) { lock.lock(); _running = v; lock.unlock() }

    var onStatus: ((SessionStatus) -> Void)?

    // Stav, se kterým pracuje jen pracovní vlákno
    private var status = SessionStatus()
    private var mode: ContentMode = .none
    private var model: DashModel = .unknown
    private var zoomLevel = 7
    private var seq = 1
    private var lastTbtIndex = -1
    private var lastSpeedLog = Date.distantPast

    // MARK: Start / stop (volat z hlavního vlákna)
    func start() {
        guard !isRunning else { log("Session už běží"); return }
        let accs = EAAccessoryManager.shared().connectedAccessories
        log("Připojená příslušenství: \(accs.count)")
        for a in accs { log("  • \(DashLink.describe(a))") }
        guard let acc = DashLink.findAccessory() else {
            log("❌ Žádné příslušenství s protokolem \(DashLink.proto). Je motorka spárovaná v Bluetooth, zapnuté zapalování a na přístrojovce vybraná navigace?")
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

    // MARK: Hlavní běh
    private func run(_ acc: EAAccessory) {
        status = SessionStatus()
        mode = .none
        model = .unknown
        lastTbtIndex = -1
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
        // Pillion posílá obrázky hned po handshaku a funguje – začneme v režimu mapy,
        // a pak se řídíme tím, co si motorka vyžádá zprávou 55/56.
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
        log("➡️ ESN_ACK + AUTH_REQUEST, čekám na SEC_DATA (83)…")
        guard let sec = waitFor(83, timeout: 10) else { log("❌ SEC_DATA nepřišlo"); return false }
        let part = NL.partNumber(seed: sec.payload)
        if part.contains("006-B3952") { model = .ixww22 }
        else if part.contains("006-B4160") || part.contains("006-B4920") { model = .imww23 }
        status.partNumber = part
        status.model = model
        log("⬅️ Číslo dílu přístrojovky: \(part) → model \(model.rawValue)")
        guard let ack = NL.secDataAck(seed: sec.payload) else { log("❌ Vadné SEC_DATA"); return false }
        send(ack)
        // Nastavovací dávka (stejné pořadí jako Pillion, ale km/h a metrický zoom)
        send(NL.flag(2, false))                    // NAV_STATUS
        send(NL.dayNight(1))                       // den
        send(NL.flag(10, false))                   // domov nenastaven
        send(NL.flag(11, false))                   // práce nenastavena
        send(NL.flag(13, true))                    // GPS OK
        send(NL.flag(12, false))                   // init setup: zatím ne
        send(NL.zoom(current: zoomLevel, lo: 0, hi: 25, label: "200 m", show: false))
        send(NL.currentRoad(""))
        send(NL.speedLimit(0, unit: "km/h"))       // 0 = limit neznámý
        send(NL.flag(13, true))
        send(NL.flag(12, true))                    // init setup complete
        send(NL.flag(2, true))                     // „navigujeme“
        log("✅ Autentizace + nastavení odesláno")
        return true
    }

    private func loop() {
        var lastNav = Date()
        var lastImage = Date.distantPast
        var awaitingAck = false
        var ackSentAt = Date()
        var acksInWindow = 0
        var windowStart = Date()
        var lastSummary = Date()

        while isRunning && link.isOpen {
            // 1) Příchozí zprávy (max 30 najednou, ať neblokují odesílání)
            var got = 0
            while got < 30, let f = link.readFrame(timeout: got == 0 ? 0.02 : 0) {
                got += 1
                if f.svc == 80 {
                    if awaitingAck {
                        awaitingAck = false
                        acksInWindow += 1
                        status.imagesAcked += 1
                    }
                } else {
                    handle(f)
                }
            }
            let now = Date()
            let o = options

            // 2) Navigační data 1× za sekundu
            if now.timeIntervalSince(lastNav) >= 1.0 {
                sim.tick(now.timeIntervalSince(lastNav))
                lastNav = now
                if o.sendNavData { sendNav(o) }
            }

            // 3) Obrázky – jen v režimu mapy, vždy až po ACK předchozího
            if mode == .map && o.sendImages {
                if awaitingAck && now.timeIntervalSince(ackSentAt) > 3 {
                    log("⚠️ IMAGE_ACK nepřišel do 3 s")
                    awaitingAck = false
                }
                if !awaitingAck && now.timeIntervalSince(lastImage) >= 1.0 / max(1, o.imageFps) {
                    let note = "NaviTest · \(mode.rawValue) · nav:\(o.sendNavData ? "ANO" : "NE")"
                    if let jpg = renderer.render(frame: seq, sim: sim.snapshot(), quality: o.jpegQuality, note: note) {
                        send(NL.image(seq: seq, jpeg: jpg))
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

            // 4) Stav do UI
            if now.timeIntervalSince(windowStart) >= 2 {
                status.fps = Double(acksInWindow) / now.timeIntervalSince(windowStart)
                acksInWindow = 0
                windowStart = now
                publish()
            }
            if now.timeIntervalSince(lastSummary) >= 15 {
                lastSummary = now
                log(String(format: "ℹ️ režim %@, obrázky %.1f fps (%ld kB), potvrzeno %ld, nav zpráv %ld, fronta %ld B",
                           mode.rawValue, status.fps, status.lastKB, status.imagesAcked, status.navSent, link.pendingTx))
            }
        }
        if !link.isOpen { log("Spojení s motorkou zavřeno") }
    }

    // MARK: Příchozí zprávy
    private func handle(_ f: InFrame) {
        status.lastRx = "\(f.svc) \(NL.name(f.svc))"
        switch f.svc {
        case 55:
            let ct = f.payload.first ?? 0
            log("⬅️ Motorka žádá START obsahu: \(NL.contentName(ct)) [payload \(f.payload.hex)]")
            if ct == 1 {
                mode = .map
                send(NL.flag(2, true)); send(NL.flag(13, true)); send(NL.flag(12, true))
                send(NL.zoom(current: zoomLevel, lo: 0, hi: 25, label: zoomLabel(), show: false))
            } else if ct == 2 {
                mode = .tbt
                lastTbtIndex = -1
                sendTbtList(sim.snapshot())
            }
            publish()
        case 56:
            let ct = f.payload.first ?? 0
            log("⬅️ Motorka žádá STOP obsahu: \(NL.contentName(ct)) [payload \(f.payload.hex)]")
            if ct == 1 && mode == .map { send(NL.imageStopped()); mode = .none }
            if ct == 2 && mode == .tbt { mode = .none }
            publish()
        case 51, 52:
            zoomLevel = f.svc == 51 ? max(0, zoomLevel - 1) : min(25, zoomLevel + 1)
            log("⬅️ Joystick: \(f.svc == 51 ? "ZOOM +" : "ZOOM −") → úroveň \(zoomLevel)")
            send(NL.zoom(current: zoomLevel, lo: 0, hi: 25, label: zoomLabel(), show: true))
        case 65:
            if Date().timeIntervalSince(lastSpeedLog) > 10 {
                lastSpeedLog = Date()
                log("⬅️ Rychlost z motorky: payload \(f.payload.hex)")
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
    private func sendNav(_ o: TestOptions) {
        let s = sim.snapshot()
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
            send(NL.navInfo(icon: s.maneuver.icon, dist: d, unit: u, road: s.maneuver.road,
                            remain: rd, remainUnit: ru, minutes: s.minutesLeft, lanes: s.maneuver.lanes))
        }
        if use4 { send(NL.nextTurn(icon: s.maneuver.icon, dist: d, unit: u, road: s.maneuver.road)) }
        send(NL.currentRoad(s.currentRoad))
        send(NL.speedLimit(s.speedLimit, unit: "km/h"))
        send(NL.eta(hour: s.eta.hour, minute: s.eta.minute))
        status.navSent += 1

        if mode == .tbt {
            if s.index != lastTbtIndex { sendTbtList(s) }
            else {
                // průběžně aktualizuj vzdálenost u první položky
                let (dd, uu) = formatDistance(s.toNext)
                send(NL.tbtItem(index: 0, icon: s.maneuver.icon, dist: dd, unit: uu, text: s.maneuver.text))
            }
        }
    }

    private func sendTbtList(_ s: SimSnapshot) {
        lastTbtIndex = s.index
        send(NL.tbtListUpdate(count: s.upcoming.count, hasMore: false))
        for (i, item) in s.upcoming.enumerated() {
            let (d, u) = formatDistance(item.1)
            send(NL.tbtItem(index: i, icon: item.0.icon, dist: d, unit: u, text: item.0.text))
        }
        send(NL.activeTbt(0))
        log("➡️ Turn-by-turn seznam: \(s.upcoming.count) položek")
    }

    private func zoomLabel() -> String {
        let meters = [20, 30, 50, 80, 120, 200, 300, 500, 800, 1200, 2000, 3000, 5000]
        let m = meters[min(meters.count - 1, max(0, zoomLevel - 2))]
        return m < 1000 ? "\(m) m" : "\(m / 1000) km"
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
        let s = status
        onStatus?(s)
    }
}

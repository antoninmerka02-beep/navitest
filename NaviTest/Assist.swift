import Foundation
import MapKit

// MARK: - Nastavení
enum SpeedSource: String, Codable, CaseIterable, Identifiable {
    case actual, speedometer
    var id: String { rawValue }
    var label: String { self == .actual ? T("Actual speed") : T("Speedometer") }
}

struct AssistSettings: Codable {
    var cameras = true
    var schools = true
    var borders = true
    var speeding = true
    var tolerance = 5                          // km/h nad limit, než se upozorní
    var speedSource: SpeedSource = .speedometer
    var speedoCorrection = 7                   // o kolik % tachometr ukazuje víc
    var warnDistance = 15.0                    // sekund dopředu (při dané rychlosti) – blízko/normálně/daleko
    var cameraSound: AlertSound = .laser
    var sectionSound: AlertSound = .radar
    var schoolSound: AlertSound = .chime
    var speedingSound: AlertSound = .tripleBeep
    var cameraVoice = true
    var sectionVoice = true
    var schoolVoice = true
    var speedingVoice = true
    var alertVolume: Double = 1.0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AssistSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        cameras = v(.cameras, d.cameras); schools = v(.schools, d.schools); borders = v(.borders, d.borders)
        speeding = v(.speeding, d.speeding); tolerance = v(.tolerance, d.tolerance)
        speedSource = v(.speedSource, d.speedSource); speedoCorrection = v(.speedoCorrection, d.speedoCorrection)
        warnDistance = v(.warnDistance, d.warnDistance)
        cameraSound = v(.cameraSound, d.cameraSound); sectionSound = v(.sectionSound, d.sectionSound)
        schoolSound = v(.schoolSound, d.schoolSound); speedingSound = v(.speedingSound, d.speedingSound)
        cameraVoice = v(.cameraVoice, d.cameraVoice); sectionVoice = v(.sectionVoice, d.sectionVoice)
        schoolVoice = v(.schoolVoice, d.schoolVoice); speedingVoice = v(.speedingVoice, d.speedingVoice)
        alertVolume = v(.alertVolume, d.alertVolume)
    }
}

/// Druh upozornění (pro zvuk, text a ikonu).
enum AlertKind { case camera, redLight, section, school, speeding }

/// Co má appka udělat: zpráva na přístrojovku a/nebo zvuk.
enum AssistAction {
    case dash(NLMessage)
    case sound(AlertKind, Int)            // druh + limit (0 = neznámý)
}

/// Bod pro mapu v motorce (ikonka).
struct AssistPOI {
    let coordinate: CLLocationCoordinate2D
    let kind: AlertKind
    var limit: Int = 0
    var line: [CLLocationCoordinate2D] = []    // u úsekového měření průběh úseku
}

// MARK: - Data jedné buňky (~3,3 × 3,3 km)
struct AssistCell: Codable {
    struct Cam: Codable { let lat: Double; let lon: Double; let limit: Int; let dir: Double?; let avg: Bool; let red: Bool }
    struct Sec: Codable { let fLat: Double; let fLon: Double; let tLat: Double; let tLon: Double; let limit: Int }
    struct Way: Codable { let pts: [[Double]]; let kmh: Int; let name: String; let oneway: Bool }
    var fetched: Date
    var waysOK: Bool? = nil          // false = limity se ještě nepodařilo stáhnout (radary už ano)
    var cams: [Cam] = []
    var secs: [Sec] = []
    var schools: [[Double]] = []
    var ways: [Way] = []
}

/// Stahování a ukládání dat po buňkách – malé dotazy projdou spolehlivěji a znovu se nestahují.
final class AssistStore {
    static let shared = AssistStore()
    static let latStep = 0.03, lonStep = 0.045
    private static let servers = ["https://overpass-api.de/api/interpreter",
                                  "https://overpass.private.coffee/api/interpreter",
                                  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
                                  "https://overpass.kumi.systems/api/interpreter",
                                  "https://overpass.osm.ch/api/interpreter",
                                  "https://overpass.openstreetmap.ru/api/interpreter"]
    private let lock = NSLock()
    private var mem: [String: AssistCell] = [:]
    private var queue: [String] = []
    private var queued = Set<String>()
    private var failedAt: [String: Date] = [:]
    private var working = false
    private var serverIndex = 0
    private var serverCoolUntil: [String: Date] = [:]
    private let dir: URL
    var onUpdate: (() -> Void)?
    private var loggedTags = Set<String>()

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("assist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func key(_ c: CLLocationCoordinate2D) -> String {
        "\(Int(floor(c.latitude / latStep)))_\(Int(floor(c.longitude / lonStep)))"
    }

    static func keys(around c: CLLocationCoordinate2D) -> [String] {
        let i = Int(floor(c.latitude / latStep)), j = Int(floor(c.longitude / lonStep))
        var out: [String] = ["\(i)_\(j)"]
        for di in -1...1 { for dj in -1...1 where !(di == 0 && dj == 0) { out.append("\(i + di)_\(j + dj)") } }
        return out
    }

    /// Buňky podél trasy (v pořadí jízdy), včetně sousedních u okraje.
    static func keys(along pts: [MKMapPoint], cum: [Double]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var next = 0.0
        for i in 0..<pts.count where cum[i] >= next || i == pts.count - 1 {
            next = cum[i] + 400
            let c = pts[i].coordinate
            for (dl, dn) in [(0.0, 0.0), (0.002, 0.0), (-0.002, 0.0), (0.0, 0.003), (0.0, -0.003)] {
                let k = key(CLLocationCoordinate2D(latitude: c.latitude + dl, longitude: c.longitude + dn))
                if seen.insert(k).inserted { out.append(k) }
            }
        }
        return out
    }

    func cell(_ k: String) -> AssistCell? {
        lock.lock()
        if let c = mem[k] { lock.unlock(); return c }
        lock.unlock()
        let f = dir.appendingPathComponent("\(k).json")
        guard let d = try? Data(contentsOf: f), let c = try? JSONDecoder().decode(AssistCell.self, from: d) else { return nil }
        lock.lock(); mem[k] = c; lock.unlock()
        return c
    }

    private func fresh(_ k: String) -> Bool {
        guard let c = cell(k) else { return false }
        return Date().timeIntervalSince(c.fetched) < 7 * 86_400 && c.waysOK != false
    }

    /// Zařadí buňky ke stažení (co je čerstvé v mezipaměti, přeskočí).
    func request(_ keys: [String]) {
        lock.lock()
        for k in keys where !queued.contains(k) {
            if let f = failedAt[k], Date().timeIntervalSince(f) < 60 { continue }
            queued.insert(k); queue.append(k)
        }
        let start = !working && !queue.isEmpty
        if start { working = true }
        lock.unlock()
        if start { DispatchQueue.global(qos: .utility).async { self.work() } }
    }

    private func work() {
        while true {
            lock.lock()
            guard !queue.isEmpty else { working = false; lock.unlock(); return }
            let k = queue.removeFirst()
            lock.unlock()
            if fresh(k) {
                lock.lock(); queued.remove(k); lock.unlock()
                continue
            }
            let parts = k.split(separator: "_").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            let s = Double(parts[0]) * AssistStore.latStep, w = Double(parts[1]) * AssistStore.lonStep
            let bbox = String(format: "%.5f,%.5f,%.5f,%.5f", s, w, s + AssistStore.latStep, w + AssistStore.lonStep)
            // 1) lehký dotaz: radary, úseková měření, školy – malý, projde skoro vždy
            var cur = self.cell(k)
            let needLight = cur == nil || Date().timeIntervalSince(cur!.fetched) >= 7 * 86_400
            if needLight {
                var got: AssistCell? = nil
                for attempt in 0..<3 {
                    if let els = query(bbox, heavy: false) { got = build(els); break }
                    Thread.sleep(forTimeInterval: attempt < 1 ? 2 : 5)
                }
                if var c = got {
                    c.waysOK = false
                    save(k, c)
                    cur = c
                    onUpdate?()
                }
            }
            // 2) těžší dotaz: rychlostní limity (silnice s maxspeed) – smí přijít později
            var ok = false
            if var c = cur {
                for attempt in 0..<3 {
                    if let els = query(bbox, heavy: true) {
                        c.ways = build(els).ways
                        c.waysOK = true
                        save(k, c)
                        ok = true
                        break
                    }
                    Thread.sleep(forTimeInterval: attempt < 1 ? 3 : 8)
                }
            }
            lock.lock()
            queued.remove(k)
            if !ok { failedAt[k] = Date() }
            lock.unlock()
            if ok { onUpdate?() }
            else if cur != nil { log("⚠️ Asistence: buňka \(k) – radary ano, limity zatím ne, zkusím později") }
            else { log("⚠️ Asistence: buňku \(k) se nepodařilo stáhnout, zkusím později") }
        }
    }

    /// Nejbližší server, který v posledních 90 s neselhal (a posune se dál – rovnoměrně je střídá).
    private func nextServer() -> String {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        for _ in 0..<AssistStore.servers.count {
            let s = AssistStore.servers[serverIndex % AssistStore.servers.count]
            serverIndex += 1
            if (serverCoolUntil[s] ?? .distantPast) < now { return s }
        }
        return AssistStore.servers[serverIndex % AssistStore.servers.count]
    }

    private func save(_ k: String, _ c: AssistCell) {
        lock.lock(); mem[k] = c; lock.unlock()
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: dir.appendingPathComponent("\(k).json"), options: .atomic) }
    }

    private func query(_ bbox: String, heavy: Bool) -> [[String: Any]]? {
        let hw = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"
        let q = heavy ? """
        [out:json][timeout:40];
        way["highway"~"^(\(hw))$"]["maxspeed"](\(bbox));
        out body geom;
        """ : """
        [out:json][timeout:20];
        (
          node["highway"="speed_camera"](\(bbox));
          relation["type"="enforcement"](\(bbox));
          node["hazard"="school_zone"](\(bbox));
          way["hazard"="school_zone"](\(bbox));
        );
        out body geom;
        """
        let server = nextServer()
        guard let url = URL(string: server) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: heavy ? 45 : 25)
        req.httpMethod = "POST"
        req.setValue("NaviTest-R9/1.0 (iOS; hobby motorcycle navigation)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = ("data=" + (q.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).data(using: .utf8)
        let sem = DispatchSemaphore(value: 0)
        var result: [[String: Any]]? = nil
        var code = 0
        var errText = ""
        URLSession.shared.dataTask(with: req) { d, resp, err in
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, let d = d,
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let els = obj["elements"] as? [[String: Any]] {
                result = els
            }
            errText = err?.localizedDescription ?? ""
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + (heavy ? 50 : 30))
        if result == nil {
            log("⚠️ Overpass \(URL(string: server)?.host ?? server): HTTP \(code) \(errText)")
            lock.lock(); serverCoolUntil[server] = Date().addingTimeInterval(code == 429 ? 120 : 60); lock.unlock()
        }
        return result
    }

    static func parseSpeed(_ s: String?) -> Int {
        guard var t = s?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return 0 }
        let named: [String: Int] = ["cz:urban": 50, "cz:rural": 90, "cz:motorway": 130, "cz:trunk": 110,
                                    "sk:urban": 50, "sk:rural": 90, "sk:motorway": 130,
                                    "de:urban": 50, "de:rural": 100, "at:urban": 50, "at:rural": 100,
                                    "at:motorway": 130, "pl:urban": 50, "pl:rural": 90, "pl:motorway": 140]
        if let n = named[t] { return n }
        if t.contains(";") { t = String(t.split(separator: ";").first ?? "") }
        let mph = t.contains("mph")
        t = t.filter { $0.isNumber }
        guard let v = Int(t), v > 0, v < 200 else { return 0 }
        return mph ? Int((Double(v) * 1.609).rounded()) : v
    }

    private func coord(_ e: [String: Any]) -> [Double]? {
        guard let lat = e["lat"] as? Double, let lon = e["lon"] as? Double else { return nil }
        return [lat, lon]
    }

    private func geometry(_ e: [String: Any]) -> [[Double]] {
        (e["geometry"] as? [[String: Any]] ?? []).compactMap { coord($0) }
    }

    private func build(_ els: [[String: Any]]) -> AssistCell {
        var c = AssistCell(fetched: Date())
        for e in els {
            let type = e["type"] as? String ?? ""
            let tags = e["tags"] as? [String: String] ?? [:]
            if type == "node", tags["highway"] == "speed_camera", let p = coord(e) {
                let all = tags.map { "\($0.key)=\($0.value)" }.joined(separator: ",").lowercased()
                let avg = all.contains("average") || all.contains("section")
                let red = all.contains("traffic_signals") || all.contains("red_light")
                var dir: Double? = nil
                if let d = tags["direction"], !d.contains(";"), let v = Double(d.filter { $0.isNumber || $0 == "." }) { dir = v }
                c.cams.append(.init(lat: p[0], lon: p[1], limit: AssistStore.parseSpeed(tags["maxspeed"]), dir: dir, avg: avg, red: red))
                // Do logu jednou za běh: jak jsou radary v datech označené
                let sig = tags.keys.filter { $0 != "name" && $0 != "highway" }.sorted().map { "\($0)=\(tags[$0] ?? "")" }.joined(separator: ", ")
                lock.lock(); let isNew = loggedTags.insert(sig).inserted; lock.unlock()
                if isNew { log("📷 Radar v datech: \(sig.isEmpty ? "(bez dalších tagů)" : sig)") }
            } else if type == "relation", tags["type"] == "enforcement" {
                let kind = tags["enforcement"] ?? "maxspeed"
                let lim = AssistStore.parseSpeed(tags["maxspeed"])
                let members = e["members"] as? [[String: Any]] ?? []
                func member(_ roles: [String]) -> [Double]? {
                    for m in members where roles.contains(m["role"] as? String ?? "") {
                        if let p = coord(m) { return p }
                        if let p = geometry(m).first { return p }
                    }
                    return nil
                }
                if kind == "average_speed", let f = member(["from", "device"]), let t = member(["to"]) {
                    c.secs.append(.init(fLat: f[0], fLon: f[1], tLat: t[0], tLon: t[1], limit: lim))
                } else if let p = member(["device", "from"]) {
                    c.cams.append(.init(lat: p[0], lon: p[1], limit: lim, dir: nil,
                                        avg: kind == "average_speed", red: kind == "traffic_signals"))
                }
            } else if tags["hazard"] == "school_zone" {
                if type == "node", let p = coord(e) { c.schools.append(p) }
                else if let p = geometry(e).first { c.schools.append(p) }
            } else if type == "way", let ms = tags["maxspeed"] {
                let kmh = AssistStore.parseSpeed(ms)
                let pts = geometry(e).map { [($0[0] * 1e5).rounded() / 1e5, ($0[1] * 1e5).rounded() / 1e5] }
                guard kmh > 0, pts.count >= 2 else { continue }
                c.ways.append(.init(pts: pts, kmh: kmh, name: tags["name"] ?? tags["ref"] ?? "",
                                    oneway: tags["oneway"] == "yes" || tags["highway"] == "motorway"))
            }
        }
        return c
    }
}

// MARK: - Data promítnutá na trasu (vzdálenosti = metry od začátku trasy)
struct AssistData {
    struct Camera { let at: Double; let type: UInt8; let limit: Int; let coordinate: CLLocationCoordinate2D }
    struct Section { let from: Double; let to: Double; let limit: Int; let coordinate: CLLocationCoordinate2D }
    struct School { let at: Double; let coordinate: CLLocationCoordinate2D }
    struct Limit { let from: Double; let to: Double; let kmh: Int }
    var cameras: [Camera] = []
    var sections: [Section] = []
    var schools: [School] = []
    var limits: [Limit] = []
}

private struct FreeSeg { let a: MKMapPoint; let b: MKMapPoint; let kmh: Int; let name: String; let oneway: Bool }

// MARK: - Vyhodnocení za jízdy
final class AssistEngine {
    private let lock = NSLock()
    private let store = AssistStore.shared

    // trasa
    private var routePts: [MKMapPoint] = []
    private var routeCum: [Double] = []
    private var routeKeys: [String] = []
    private var routeGen = -1
    private var data = AssistData()

    // volná jízda
    private var freeKeys: [String] = []
    private var freeCenter: CLLocation? = nil
    private var freeWays: [FreeSeg] = []
    private var freeCams: [AssistCell.Cam] = []
    private var freeSecs: [AssistCell.Sec] = []
    private var freeSchools: [[Double]] = []
    private var freeLimit = 0
    private var freeRoad = ""
    private var lastFreeRoadCheck = Date.distantPast

    // stav upozornění
    private var warned = Set<String>()
    private var active: [String: Date] = [:]
    private var lastRefresh = Date.distantPast
    private var speedingActive = false
    private var speedingLimit = 0
    private(set) var summary = ""

    init() {
        store.onUpdate = { [weak self] in self?.rebuild() }
    }

    // MARK: Trasa
    func setRoute(points: [MKMapPoint], cum: [Double], generation gen: Int) {
        lock.lock()
        if gen == routeGen { lock.unlock(); return }
        routeGen = gen
        routePts = points
        routeCum = cum
        routeKeys = AssistStore.keys(along: points, cum: cum)
        warned.removeAll(); active.removeAll()
        let keys = routeKeys
        lock.unlock()
        store.request(keys)
        DispatchQueue.global(qos: .utility).async { self.rebuild() }
    }

    func clear() {
        lock.lock()
        routePts = []; routeCum = []; routeKeys = []; routeGen = -1
        data = AssistData(); summary = ""
        warned.removeAll(); active.removeAll()
        lock.unlock()
    }

    /// Přepočet dat po stažení další buňky.
    private func rebuild() {
        lock.lock()
        let pts = routePts, cum = routeCum, keys = routeKeys, fk = freeKeys
        lock.unlock()
        if !pts.isEmpty {
            let d = buildRoute(pts: pts, cum: cum, keys: keys)
            let covered = d.limits.reduce(0.0) { $0 + ($1.to - $1.from) }
            let total = cum.last ?? 0
            let pct = total > 0 ? Int(min(100, covered / total * 100)) : 0
            let have = keys.filter { store.cell($0) != nil }.count
            lock.lock()
            if routePts.count == pts.count {
                data = d
                summary = "\(d.cameras.count) / \(d.sections.count) / \(d.schools.count) · \(pct) % · \(have)/\(keys.count)"
            }
            lock.unlock()
            if have == keys.count || have % 5 == 0 {
                log("🚨 Asistence: radary \(d.cameras.count), úsekové \(d.sections.count), školy \(d.schools.count), limity na \(pct) % trasy (data \(have)/\(keys.count))")
            }
        }
        if !fk.isEmpty { rebuildFree(fk) }
    }

    private func project(_ c: CLLocationCoordinate2D, _ pts: [MKMapPoint], _ cum: [Double]) -> (along: Double, dist: Double, bearing: Double) {
        let p = MKMapPoint(c)
        var best = (along: 0.0, dist: Double.infinity, bearing: 0.0)
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
            t = min(1, max(0, t))
            let q = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = q.distance(to: p)
            if d < best.dist { best = (cum[i] + a.distance(to: q), d, NavRoute.bearing(a, b)) }
        }
        return best
    }

    private static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }

    private func buildRoute(pts: [MKMapPoint], cum: [Double], keys: [String]) -> AssistData {
        guard pts.count > 1 else { return AssistData() }
        var d = AssistData()
        let cells = keys.compactMap { store.cell($0) }
        // Radary: jen blízko trasy, ve směru jízdy (když je směr v datech)
        struct Hit { let at: Double; let cam: AssistCell.Cam; let c: CLLocationCoordinate2D }
        var cams: [Hit] = []
        var seenCam = Set<String>()
        for cell in cells {
            for cam in cell.cams {
                let id = String(format: "%.5f,%.5f", cam.lat, cam.lon)
                guard seenCam.insert(id).inserted else { continue }
                let c = CLLocationCoordinate2D(latitude: cam.lat, longitude: cam.lon)
                let pr = project(c, pts, cum)
                guard pr.dist < 45 else { continue }
                if let dir = cam.dir, AssistEngine.angleDiff(dir, pr.bearing) > 100 { continue }   // radar do protisměru
                cams.append(Hit(at: pr.along, cam: cam, c: c))
            }
        }
        cams.sort { $0.at < $1.at }
        // Úsekové měření z označených radarů: páry po sobě jdoucích „average“ radarů
        var usedAvg = Set<Int>()
        let avgIdx = cams.indices.filter { cams[$0].cam.avg }
        var k = 0
        while k + 1 < avgIdx.count {
            let i = avgIdx[k], j = avgIdx[k + 1]
            let gap = cams[j].at - cams[i].at
            if gap > 300 && gap < 15_000 {
                let lim = cams[i].cam.limit > 0 ? cams[i].cam.limit : cams[j].cam.limit
                d.sections.append(.init(from: cams[i].at, to: cams[j].at, limit: lim, coordinate: cams[i].c))
                usedAvg.insert(i); usedAvg.insert(j)
                k += 2
            } else { k += 1 }
        }
        // Úseková měření z relací
        for cell in cells {
            for s in cell.secs {
                let f = project(CLLocationCoordinate2D(latitude: s.fLat, longitude: s.fLon), pts, cum)
                let t = project(CLLocationCoordinate2D(latitude: s.tLat, longitude: s.tLon), pts, cum)
                guard f.dist < 80, t.dist < 80, t.along > f.along + 100 else { continue }
                if d.sections.contains(where: { abs($0.from - f.along) < 150 }) { continue }
                d.sections.append(.init(from: f.along, to: t.along, limit: s.limit,
                                        coordinate: CLLocationCoordinate2D(latitude: s.fLat, longitude: s.fLon)))
            }
        }
        d.sections.sort { $0.from < $1.from }
        // Zbylé radary: sloučit ty blíž než 150 m (dva směry, dvojice u začátku/konce úseku)
        for (i, x) in cams.enumerated() where !usedAvg.contains(i) {
            let type: UInt8 = x.cam.red ? 5 : (x.cam.avg ? 3 : 0)
            if let last = d.cameras.last, x.at - last.at < 150 { continue }
            if d.sections.contains(where: { abs($0.from - x.at) < 150 || abs($0.to - x.at) < 150 }) { continue }
            d.cameras.append(.init(at: x.at, type: type, limit: x.cam.limit, coordinate: x.c))
        }
        // Školy
        var seenSchool = Set<String>()
        for cell in cells {
            for p in cell.schools {
                let id = String(format: "%.4f,%.4f", p[0], p[1])
                guard seenSchool.insert(id).inserted else { continue }
                let c = CLLocationCoordinate2D(latitude: p[0], longitude: p[1])
                let pr = project(c, pts, cum)
                if pr.dist < 60 { d.schools.append(.init(at: pr.along, coordinate: c)) }
            }
        }
        d.schools.sort { $0.at < $1.at }
        // Limity: silnice souběžná s trasou (ve stejném směru, u obousměrných i opačně)
        var seenWay = Set<String>()
        for cell in cells {
            for w in cell.ways {
                guard let f = w.pts.first else { continue }
                let id = "\(f[0]),\(f[1]),\(w.pts.count),\(w.kmh)"
                guard seenWay.insert(id).inserted else { continue }
                var alongs: [Double] = []
                for (i, p) in w.pts.enumerated() {
                    let pr = project(CLLocationCoordinate2D(latitude: p[0], longitude: p[1]), pts, cum)
                    guard pr.dist < 15 else { continue }
                    let q = w.pts[min(i + 1, w.pts.count - 1)], o = w.pts[max(i - 1, 0)]
                    let wb = NavRoute.bearing(MKMapPoint(CLLocationCoordinate2D(latitude: o[0], longitude: o[1])),
                                              MKMapPoint(CLLocationCoordinate2D(latitude: q[0], longitude: q[1])))
                    let diff = AssistEngine.angleDiff(wb, pr.bearing)
                    if diff < 35 || (!w.oneway && diff > 145) { alongs.append(pr.along) }
                }
                guard alongs.count >= 2, let lo = alongs.min(), let hi = alongs.max(), hi - lo > 30 else { continue }
                d.limits.append(.init(from: lo, to: hi, kmh: w.kmh))
            }
        }
        d.limits.sort { $0.from < $1.from }
        return d
    }

    func limit(at a: Double) -> Int {
        lock.lock(); defer { lock.unlock() }
        return routeLimitLocked(a)
    }

    private func routeLimitLocked(_ a: Double) -> Int {
        var l = 0
        for x in data.limits where a >= x.from && a <= x.to { l = x.kmh }
        for s in data.sections where a >= s.from && a <= s.to && s.limit > 0 { l = l == 0 ? s.limit : min(l, s.limit) }
        return l
    }

    // MARK: Volná jízda
    var currentFreeLimit: Int { lock.lock(); defer { lock.unlock() }; return freeLimit }
    var currentFreeRoad: String { lock.lock(); defer { lock.unlock() }; return freeRoad }

    private func rebuildFree(_ keys: [String]) {
        var ways: [FreeSeg] = []
        var cams: [AssistCell.Cam] = [], secs: [AssistCell.Sec] = [], schools: [[Double]] = []
        for k in keys {
            guard let c = store.cell(k) else { continue }
            for w in c.ways where w.pts.count >= 2 {
                for i in 0..<(w.pts.count - 1) {
                    ways.append(FreeSeg(a: MKMapPoint(CLLocationCoordinate2D(latitude: w.pts[i][0], longitude: w.pts[i][1])),
                                        b: MKMapPoint(CLLocationCoordinate2D(latitude: w.pts[i + 1][0], longitude: w.pts[i + 1][1])),
                                        kmh: w.kmh, name: w.name, oneway: w.oneway))
                }
            }
            cams += c.cams; secs += c.secs; schools += c.schools
        }
        lock.lock()
        freeWays = ways; freeCams = cams; freeSecs = secs; freeSchools = schools
        lock.unlock()
    }

    // MARK: Hlavní vyhodnocení (hlavní vlákno, při každé poloze)
    /// `along` = poloha na trase (nil = volná jízda).
    func update(along: Double?, position: CLLocationCoordinate2D?, heading: Double,
                bikeKmh: Double, gpsKmh: Double, settings st: AssistSettings) -> [AssistAction] {
        let speed = bikeKmh >= 0 ? bikeKmh : gpsKmh
        // Volná jízda: zajistit data kolem polohy
        if along == nil, let p = position {
            let loc = CLLocation(latitude: p.latitude, longitude: p.longitude)
            lock.lock()
            let need = freeCenter.map { $0.distance(from: loc) > 300 } ?? true
            if need { freeCenter = loc }
            lock.unlock()
            if need {
                let keys = AssistStore.keys(around: p)
                lock.lock(); let changed = keys != freeKeys; freeKeys = keys; lock.unlock()
                store.request(keys)
                if changed { DispatchQueue.global(qos: .utility).async { self.rebuildFree(keys) } }
            }
        }
        lock.lock(); defer { lock.unlock() }
        var out: [AssistAction] = []
        let v = max(8.0, speed / 3.6)
        let warnD = max(200.0, v * st.warnDistance)
        // Po trase je poloha radaru z předstažených dat jistá, takže je bezpečné upozornit dřív
        // (radar může vyžadovat brzdění, ne jen odbočení).
        let routeWarnD = along != nil ? warnD * 1.6 : warnD
        let refresh = Date().timeIntervalSince(lastRefresh) > 3
        if refresh { lastRefresh = Date() }

        func camMsg(_ lim: Int, _ dist: Double, _ type: UInt8) -> NLMessage {
            let (lv, lu) = speedValue(kmh: lim)
            return NL.speedCamera(limit: lim > 0 ? "\(lv) \(lu)" : "", distance: formatDistanceText(max(0, dist)), cameraType: type, show: true)
        }
        func approach(_ key: String, _ dist: Double, _ passedAt: Double, _ msg: NLMessage, _ clear: NLMessage,
                      _ kind: AlertKind, _ lim: Int, _ warnDist: Double) {
            if dist < passedAt {
                if active.removeValue(forKey: key) != nil { out.append(.dash(clear)) }
                return
            }
            guard dist <= warnDist else { return }
            if !warned.contains(key) {
                warned.insert(key); active[key] = Date()
                out.append(.dash(msg)); out.append(.sound(kind, lim))
                log("🚨 Upozornění \(key): \(kind), limit \(lim), vzdálenost \(Int(dist)) m")
            } else if refresh && active[key] != nil {
                out.append(.dash(msg))
            }
        }

        var limitNow = 0
        if let a = along {
            // ---- Po trase
            if st.cameras {
                for (i, c) in data.cameras.enumerated() {
                    let lim = c.limit > 0 ? c.limit : routeLimitLocked(c.at)
                    approach("c\(i)", c.at - a, -30, camMsg(lim, c.at - a, c.type), NL.speedCameraClear(),
                             c.type == 5 ? .redLight : (c.type == 3 ? .section : .camera), lim, routeWarnD)
                }
                for (i, s) in data.sections.enumerated() {
                    approach("s\(i)", s.from - a, -80, camMsg(s.limit, s.from - a, 3), NL.speedCameraClear(), .section, s.limit, routeWarnD)
                }
            }
            if st.schools {
                for (i, z) in data.schools.enumerated() {
                    approach("z\(i)", z.at - a, -100, NL.schoolZone(distance: formatDistanceText(max(0, z.at - a)), show: true),
                             NL.schoolZoneClear(), .school, 0, max(200, warnD * 0.7))
                }
            }
            limitNow = routeLimitLocked(a)
        } else if let p = position {
            // ---- Volná jízda: silnice, po které jedu = nejbližší úsek ve směru jízdy
            let me = MKMapPoint(p)
            let staleFree = Date().timeIntervalSince(lastFreeRoadCheck) > 2
            if speed > 5 || freeLimit == 0 || staleFree {
                lastFreeRoadCheck = Date()
                var bestD = Double.infinity, bestKmh = 0, bestName = ""
                for w in freeWays {
                    let dx = w.b.x - w.a.x, dy = w.b.y - w.a.y
                    let len2 = dx * dx + dy * dy
                    guard len2 > 0 else { continue }
                    var t = ((me.x - w.a.x) * dx + (me.y - w.a.y) * dy) / len2
                    t = min(1, max(0, t))
                    let q = MKMapPoint(x: w.a.x + t * dx, y: w.a.y + t * dy)
                    let d = q.distance(to: me)
                    guard d < 20, d < bestD else { continue }
                    let diff = AssistEngine.angleDiff(NavRoute.bearing(w.a, w.b), heading)
                    guard diff < 40 || (!w.oneway && diff > 140) else { continue }
                    bestD = d; bestKmh = w.kmh; bestName = w.name
                }
                if bestKmh > 0 { freeLimit = bestKmh; freeRoad = bestName }
                else if speed > 5 || staleFree { freeLimit = 0; freeRoad = "" }
            }
            limitNow = freeLimit
            // Radary a školy před námi (v kuželu ±25° ve směru jízdy)
            func ahead(_ lat: Double, _ lon: Double) -> Double? {
                let c = MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                let d = me.distance(to: c)
                if d < 40 { return 0 }
                let diff = AssistEngine.angleDiff(NavRoute.bearing(me, c), heading)
                if diff > 90 { return -d }                  // za námi
                return (diff < 25 && d * sin(diff * .pi / 180) < 40) ? d : nil
            }
            if st.cameras {
                // Kandidáti před námi, seřazení podle vzdálenosti; blízké dvojice (do 150 m) sloučit do jedné
                struct Ahead { let d: Double; let cam: AssistCell.Cam }
                var ahd: [Ahead] = []
                for cam in freeCams {
                    if let dir = cam.dir, AssistEngine.angleDiff(dir, heading) > 100 { continue }
                    guard let d = ahead(cam.lat, cam.lon) else { continue }
                    ahd.append(Ahead(d: d, cam: cam))
                }
                ahd.sort { $0.d < $1.d }
                var lastKeptD = -1000.0
                var lastKeptKey = ""
                for h in ahd {
                    let key = String(format: "f%.5f,%.5f", h.cam.lat, h.cam.lon)
                    if h.d - lastKeptD < 150 && h.d >= 0 {
                        // stejná dvojice jako poslední ponechaná – jen ji „přepínáme“ na bližší souřadnici,
                        // ale nezakládáme nové upozornění
                        if active[lastKeptKey] != nil { active[key] = active[lastKeptKey] }
                        continue
                    }
                    lastKeptD = h.d; lastKeptKey = key
                    let type: UInt8 = h.cam.red ? 5 : (h.cam.avg ? 3 : 0)
                    let lim = h.cam.limit > 0 ? h.cam.limit : freeLimit
                    approach(key, h.d, -30, camMsg(lim, h.d, type), NL.speedCameraClear(),
                             type == 5 ? .redLight : (type == 3 ? .section : .camera), lim, warnD)
                }
                for s in freeSecs {
                    guard let d = ahead(s.fLat, s.fLon) else { continue }
                    let key = String(format: "fs%.5f,%.5f", s.fLat, s.fLon)
                    approach(key, d, -80, camMsg(s.limit, d, 3), NL.speedCameraClear(), .section, s.limit, warnD)
                }
            }
            if st.schools {
                for z in freeSchools {
                    guard let d = ahead(z[0], z[1]) else { continue }
                    let key = String(format: "fz%.4f,%.4f", z[0], z[1])
                    approach(key, d, -100, NL.schoolZone(distance: formatDistanceText(max(0, d)), show: true),
                             NL.schoolZoneClear(), .school, 0, max(200, warnD * 0.7))
                }
            }
        }

        // ---- Překročení rychlosti: jednou při překročení, znovu až po zpomalení nebo změně limitu
        if limitNow != speedingLimit { speedingActive = false; speedingLimit = limitNow }
        if st.speeding, limitNow > 0 {
            let eff = st.speedSource == .speedometer ? speed * (1 + Double(st.speedoCorrection) / 100) : speed
            let threshold = Double(limitNow + st.tolerance)
            if eff > threshold && !speedingActive {
                speedingActive = true
                out.append(.dash(NL.speedingEvent()))
                out.append(.sound(.speeding, limitNow))
                let bikeText = bikeKmh >= 0 ? String(format: "%.0f km/h", bikeKmh) : "–"
                let src = st.speedSource == .speedometer ? "tachometr +\(st.speedoCorrection) %" : "skutečná"
                log(String(format: "🚨 Rychlost: motorka %@, GPS %.0f km/h, pro upozornění %.0f (%@), limit %ld + tolerance %ld, poloha %@",
                           bikeText, gpsKmh, eff, src, limitNow, st.tolerance,
                           position.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) } ?? "?"))
            } else if eff < threshold - 3 {
                speedingActive = false
            }
        }
        return out
    }

    /// Body pro mapu v motorce i v telefonu.
    func mapPOIs() -> [AssistPOI] {
        lock.lock(); defer { lock.unlock() }
        if !routePts.isEmpty {
            var out = data.cameras.map { c -> AssistPOI in
                AssistPOI(coordinate: c.coordinate, kind: c.type == 5 ? .redLight : (c.type == 3 ? .section : .camera),
                          limit: c.limit > 0 ? c.limit : routeLimitLocked(c.at))
            }
            out += data.sections.map { s in
                AssistPOI(coordinate: s.coordinate, kind: .section, limit: s.limit, line: routeCoords(from: s.from, to: s.to))
            }
            out += data.schools.map { AssistPOI(coordinate: $0.coordinate, kind: .school) }
            return out
        }
        var out = freeCams.map { c -> AssistPOI in
            AssistPOI(coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon),
                      kind: c.red ? .redLight : (c.avg ? .section : .camera), limit: c.limit)
        }
        out += freeSecs.map { s in
            AssistPOI(coordinate: CLLocationCoordinate2D(latitude: s.fLat, longitude: s.fLon), kind: .section, limit: s.limit,
                      line: [CLLocationCoordinate2D(latitude: s.fLat, longitude: s.fLon),
                             CLLocationCoordinate2D(latitude: s.tLat, longitude: s.tLon)])
        }
        out += freeSchools.map { AssistPOI(coordinate: CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]), kind: .school) }
        return out
    }

    /// Body trasy mezi dvěma vzdálenostmi (pro červenou čáru úsekového měření).
    private func routeCoords(from a: Double, to b: Double) -> [CLLocationCoordinate2D] {
        guard routePts.count > 1, b > a else { return [] }
        var out: [CLLocationCoordinate2D] = []
        for i in 0..<routePts.count where routeCum[i] >= a && routeCum[i] <= b { out.append(routePts[i].coordinate) }
        if out.count < 2 {
            out = [NavRoute.pointAt(points: routePts, cum: routeCum, d: a).coordinate,
                   NavRoute.pointAt(points: routePts, cum: routeCum, d: b).coordinate]
        }
        return out
    }
}

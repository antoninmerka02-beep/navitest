import Foundation
import MapKit

struct AssistSettings: Codable {
    var cameras = true
    var schools = true
    var borders = true
    var speeding = true
    var tolerance = 5                     // km/h nad limit, než se upozorní
    var cameraSound: AlertSound = .voice
    var sectionSound: AlertSound = .voice
    var schoolSound: AlertSound = .voice
    var speedingSound: AlertSound = .voice
    var alertVolume: Double = 1.0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AssistSettings()
        cameras = (try? c.decodeIfPresent(Bool.self, forKey: .cameras)) ?? d.cameras
        schools = (try? c.decodeIfPresent(Bool.self, forKey: .schools)) ?? d.schools
        borders = (try? c.decodeIfPresent(Bool.self, forKey: .borders)) ?? d.borders
        speeding = (try? c.decodeIfPresent(Bool.self, forKey: .speeding)) ?? d.speeding
        tolerance = (try? c.decodeIfPresent(Int.self, forKey: .tolerance)) ?? d.tolerance
        cameraSound = (try? c.decodeIfPresent(AlertSound.self, forKey: .cameraSound)) ?? d.cameraSound
        sectionSound = (try? c.decodeIfPresent(AlertSound.self, forKey: .sectionSound)) ?? d.sectionSound
        schoolSound = (try? c.decodeIfPresent(AlertSound.self, forKey: .schoolSound)) ?? d.schoolSound
        speedingSound = (try? c.decodeIfPresent(AlertSound.self, forKey: .speedingSound)) ?? d.speedingSound
        alertVolume = (try? c.decodeIfPresent(Double.self, forKey: .alertVolume)) ?? d.alertVolume
    }
}

/// Druh upozornění (pro zvuk a text).
enum AlertKind { case camera, redLight, section, school, speeding }

/// Co má appka udělat: zpráva na přístrojovku a/nebo zvuk.
enum AssistAction {
    case dash(NLMessage)
    case sound(AlertKind, Int)            // druh + limit (0 = neznámý)
}

/// Data asistence podél jedné trasy (vzdálenosti = metry od začátku trasy).
struct AssistData {
    struct Camera { let at: Double; let type: UInt8; let limit: Int }
    struct Section { let from: Double; let to: Double; let limit: Int }
    struct Limit { let from: Double; let to: Double; let kmh: Int }
    var cameras: [Camera] = []
    var sections: [Section] = []
    var schools: [Double] = []
    var limits: [Limit] = []
}

/// Radary, úsekové měření, školní zóny a limity z OpenStreetMap (Overpass API, bez klíče).
final class AssistEngine {
    private let lock = NSLock()
    private var data = AssistData()
    private var generation = -1
    private var loadingGen = -1
    private(set) var summary = ""

    // stav upozornění
    private var warned = Set<String>()
    private var active: [String: Date] = [:]         // co je zobrazené na přístrojovce
    private var lastSpeeding = Date.distantPast
    private var lastRefresh = Date.distantPast

    private static let servers = ["https://overpass-api.de/api/interpreter",
                                  "https://overpass.kumi.systems/api/interpreter"]

    // MARK: Načtení dat pro trasu
    func load(points: [MKMapPoint], cum: [Double], generation gen: Int) {
        lock.lock()
        if gen == loadingGen || gen == generation { lock.unlock(); return }
        loadingGen = gen
        warned.removeAll(); active.removeAll()
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let d = self.fetch(points: points, cum: cum)
            self.lock.lock()
            if self.loadingGen == gen {
                self.data = d
                self.generation = gen
                let covered = d.limits.reduce(0.0) { $0 + ($1.to - $1.from) }
                let pct = cum.last.map { $0 > 0 ? Int(min(100, covered / $0 * 100)) : 0 } ?? 0
                self.summary = "\(d.cameras.count) / \(d.sections.count) / \(d.schools.count) · \(pct) %"
            }
            self.lock.unlock()
            log("🚨 Asistence: radary \(d.cameras.count), úsekové \(d.sections.count), školy \(d.schools.count), limity na \(self.summary.split(separator: "·").last.map { String($0) } ?? "?") trasy")
        }
    }

    func clear() {
        lock.lock()
        data = AssistData(); generation = -1; loadingGen = -1
        warned.removeAll(); active.removeAll(); summary = ""
        lock.unlock()
    }

    /// Rychlostní limit v daném místě trasy (0 = neznámý).
    func limit(at a: Double) -> Int {
        lock.lock(); defer { lock.unlock() }
        return limitLocked(a)
    }

    private func limitLocked(_ a: Double) -> Int {
        var l = 0
        for x in data.limits where a >= x.from && a <= x.to { l = x.kmh }
        for s in data.sections where a >= s.from && a <= s.to && s.limit > 0 { l = l == 0 ? s.limit : min(l, s.limit) }
        return l
    }

    // MARK: Vyhodnocení za jízdy (volá hlavní vlákno při každé poloze)
    func update(along a: Double, speedKmh: Double, settings st: AssistSettings) -> [AssistAction] {
        lock.lock(); defer { lock.unlock() }
        var out: [AssistAction] = []
        let v = max(8.0, speedKmh / 3.6)
        let warnD = max(300.0, v * 15)
        let refresh = Date().timeIntervalSince(lastRefresh) > 3
        if refresh { lastRefresh = Date() }

        func distText(_ m: Double) -> String {
            let (d, u) = formatDistance(max(0, m))
            return u == "m" ? "\(Int(d)) m" : String(format: "%.1f km", d)
        }

        // Radary
        if st.cameras {
            for (i, c) in data.cameras.enumerated() {
                let key = "c\(i)"
                let d = c.at - a
                if d < -30 {
                    if active.removeValue(forKey: key) != nil { out.append(.dash(NL.speedCameraClear())) }
                    continue
                }
                guard d <= warnD else { continue }
                let lim = c.limit > 0 ? c.limit : limitLocked(c.at)
                let msg = NL.speedCamera(limit: lim > 0 ? "\(lim) km/h" : "", distance: distText(d), cameraType: c.type, show: true)
                if !warned.contains(key) {
                    warned.insert(key); active[key] = Date()
                    out.append(.dash(msg))
                    out.append(.sound(c.type == 5 ? .redLight : .camera, lim))
                } else if refresh && active[key] != nil {
                    out.append(.dash(msg))
                }
            }
            // Úsekové měření: upozornit před začátkem, zrušit krátce po vjezdu
            for (i, s) in data.sections.enumerated() {
                let key = "s\(i)"
                let d = s.from - a
                if d < -80 {
                    if active.removeValue(forKey: key) != nil { out.append(.dash(NL.speedCameraClear())) }
                    continue
                }
                guard d <= warnD else { continue }
                let msg = NL.speedCamera(limit: s.limit > 0 ? "\(s.limit) km/h" : "", distance: distText(d), cameraType: 3, show: true)
                if !warned.contains(key) {
                    warned.insert(key); active[key] = Date()
                    out.append(.dash(msg))
                    out.append(.sound(.section, s.limit))
                } else if refresh && active[key] != nil {
                    out.append(.dash(msg))
                }
            }
        }
        // Školní zóny
        if st.schools {
            for (i, at) in data.schools.enumerated() {
                let key = "z\(i)"
                let d = at - a
                if d < -100 {
                    if active.removeValue(forKey: key) != nil { out.append(.dash(NL.schoolZoneClear())) }
                    continue
                }
                guard d <= max(200, warnD * 0.7) else { continue }
                if !warned.contains(key) {
                    warned.insert(key); active[key] = Date()
                    out.append(.dash(NL.schoolZone(distance: distText(d), show: true)))
                    out.append(.sound(.school, 0))
                } else if refresh && active[key] != nil {
                    out.append(.dash(NL.schoolZone(distance: distText(max(0, d)), show: true)))
                }
            }
        }
        // Překročení rychlosti
        let lim = limitLocked(a)
        if st.speeding, lim > 0, speedKmh > Double(lim + st.tolerance), Date().timeIntervalSince(lastSpeeding) > 20 {
            lastSpeeding = Date()
            out.append(.dash(NL.speedingEvent()))
            out.append(.sound(.speeding, lim))
        }
        return out
    }

    // MARK: Overpass
    private func fetch(points: [MKMapPoint], cum: [Double]) -> AssistData {
        guard points.count > 1 else { return AssistData() }
        // Body trasy po ~150 m pro dotaz „around“
        var sample: [CLLocationCoordinate2D] = []
        var next = 0.0
        for i in 0..<points.count where cum[i] >= next || i == points.count - 1 {
            sample.append(points[i].coordinate)
            next = cum[i] + 150
        }
        var elements: [[String: Any]] = []
        let chunk = 220
        var start = 0
        while start < sample.count {
            let end = min(sample.count, start + chunk + 1)
            let part = Array(sample[start..<end])
            if let els = query(part) { elements += els }
            start += chunk
        }
        return build(elements, points: points, cum: cum)
    }

    private func query(_ coords: [CLLocationCoordinate2D]) -> [[String: Any]]? {
        let line = coords.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let q = """
        [out:json][timeout:40];
        (
          node(around:45,\(line))["highway"="speed_camera"];
          relation(around:60,\(line))["type"="enforcement"];
          node(around:60,\(line))["hazard"="school_zone"];
          way(around:60,\(line))["hazard"="school_zone"];
          way(around:12,\(line))["highway"]["maxspeed"];
        );
        out body geom;
        """
        for server in AssistEngine.servers {
            guard let url = URL(string: server) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 45)
            req.httpMethod = "POST"
            req.setValue("NaviTest-R9/0.9 (iOS; hobby motorcycle navigation)", forHTTPHeaderField: "User-Agent")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            req.httpBody = ("data=" + (q.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).data(using: .utf8)
            let sem = DispatchSemaphore(value: 0)
            var result: [[String: Any]]? = nil
            URLSession.shared.dataTask(with: req) { d, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, let d = d,
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let els = obj["elements"] as? [[String: Any]] {
                    result = els
                } else {
                    log("⚠️ Overpass \(server): HTTP \(code) \(err?.localizedDescription ?? "")")
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 50)
            if let r = result { return r }
        }
        return nil
    }

    // MARK: Zpracování na trasu
    private func project(_ c: CLLocationCoordinate2D, _ pts: [MKMapPoint], _ cum: [Double]) -> (along: Double, dist: Double) {
        let p = MKMapPoint(c)
        var best = (along: 0.0, dist: Double.infinity)
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
            t = min(1, max(0, t))
            let q = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = q.distance(to: p)
            if d < best.dist { best = (cum[i] + a.distance(to: q), d) }
        }
        return best
    }

    static func parseSpeed(_ s: String?) -> Int {
        guard var t = s?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return 0 }
        let named: [String: Int] = ["cz:urban": 50, "cz:rural": 90, "cz:motorway": 130, "cz:trunk": 110,
                                    "sk:urban": 50, "sk:rural": 90, "sk:motorway": 130,
                                    "de:urban": 50, "de:rural": 100, "at:urban": 50, "at:rural": 100,
                                    "at:motorway": 130, "pl:urban": 50, "pl:rural": 90, "pl:motorway": 140]
        if let n = named[t] { return n }
        let mph = t.contains("mph")
        t = t.filter { $0.isNumber }
        guard let v = Int(t), v > 0, v < 200 else { return 0 }
        return mph ? Int((Double(v) * 1.609).rounded()) : v
    }

    private func coord(_ e: [String: Any]) -> CLLocationCoordinate2D? {
        guard let lat = e["lat"] as? Double, let lon = e["lon"] as? Double else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func geometry(_ e: [String: Any]) -> [CLLocationCoordinate2D] {
        (e["geometry"] as? [[String: Any]] ?? []).compactMap { coord($0) }
    }

    private func build(_ els: [[String: Any]], points: [MKMapPoint], cum: [Double]) -> AssistData {
        var d = AssistData()
        var camSeen: [Double] = []
        func addCamera(_ at: Double, _ type: UInt8, _ lim: Int) {
            if camSeen.contains(where: { abs($0 - at) < 40 }) { return }
            camSeen.append(at)
            d.cameras.append(.init(at: at, type: type, limit: lim))
        }
        for e in els {
            let type = e["type"] as? String ?? ""
            let tags = e["tags"] as? [String: String] ?? [:]
            if type == "node", tags["highway"] == "speed_camera", let c = coord(e) {
                let pr = project(c, points, cum)
                if pr.dist < 45 { addCamera(pr.along, 0, AssistEngine.parseSpeed(tags["maxspeed"])) }
            } else if type == "relation", tags["type"] == "enforcement" {
                let kind = tags["enforcement"] ?? "maxspeed"
                let lim = AssistEngine.parseSpeed(tags["maxspeed"])
                let members = e["members"] as? [[String: Any]] ?? []
                func memberAlong(_ roles: [String]) -> Double? {
                    for m in members where roles.contains(m["role"] as? String ?? "") {
                        var cs: [CLLocationCoordinate2D] = []
                        if let c = coord(m) { cs = [c] } else { cs = geometry(m) }
                        let prs = cs.map { project($0, points, cum) }.filter { $0.dist < 80 }
                        if let best = prs.min(by: { $0.dist < $1.dist }) { return best.along }
                    }
                    return nil
                }
                if kind == "average_speed" {
                    if let f = memberAlong(["from", "device"]), let t = memberAlong(["to"]), t > f + 100 {
                        d.sections.append(.init(from: f, to: t, limit: lim))
                    } else if let f = memberAlong(["from", "device"]) {
                        addCamera(f, 3, lim)
                    }
                } else if let at = memberAlong(["device", "from"]) {
                    addCamera(at, kind == "traffic_signals" ? 5 : 0, lim)
                }
            } else if tags["hazard"] == "school_zone" {
                let cs = type == "node" ? [coord(e)].compactMap { $0 } : geometry(e)
                let prs = cs.map { project($0, points, cum) }.filter { $0.dist < 60 }
                if let first = prs.min(by: { $0.along < $1.along }) { d.schools.append(first.along) }
            } else if type == "way", let ms = tags["maxspeed"] {
                let kmh = AssistEngine.parseSpeed(ms)
                guard kmh > 0 else { continue }
                let prs = geometry(e).map { project($0, points, cum) }.filter { $0.dist < 18 }
                // Silnice, která trasu jen kříží, má u trasy 1 bod – nechceme ji
                guard prs.count >= 2, let lo = prs.map({ $0.along }).min(), let hi = prs.map({ $0.along }).max(), hi - lo > 30 else { continue }
                d.limits.append(.init(from: lo, to: hi, kmh: kmh))
            }
        }
        d.cameras.sort { $0.at < $1.at }
        d.sections.sort { $0.from < $1.from }
        d.schools.sort()
        d.limits.sort { $0.from < $1.from }
        return d
    }
}

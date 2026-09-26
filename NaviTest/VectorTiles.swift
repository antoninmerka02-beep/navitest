import Foundation
import CoreGraphics
import MapKit

// MARK: - Protobuf čtečka (jen to, co potřebuje Mapbox Vector Tile)
struct PBReader {
    let data: [UInt8]
    var pos: Int
    let end: Int

    init(_ d: [UInt8], _ start: Int = 0, _ end: Int? = nil) {
        data = d
        pos = start
        self.end = min(end ?? d.count, d.count)
    }

    var atEnd: Bool { pos >= end }

    mutating func varint() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < end {
            let b = data[pos]
            pos += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { break }
        }
        return result
    }

    mutating func key() -> (field: Int, wire: Int) {
        let k = varint()
        return (Int(k >> 3), Int(k & 7))
    }

    mutating func lengthDelimited() -> Range<Int> {
        let len = Int(clamping: varint())
        let s = pos
        pos = min(end, pos + max(0, len))
        return s..<pos
    }

    mutating func fixed32() -> UInt32 {
        guard pos + 4 <= end else { pos = end; return 0 }
        let v = UInt32(data[pos]) | UInt32(data[pos + 1]) << 8 | UInt32(data[pos + 2]) << 16 | UInt32(data[pos + 3]) << 24
        pos += 4
        return v
    }

    mutating func fixed64() -> UInt64 {
        guard pos + 8 <= end else { pos = end; return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[pos + i]) << (8 * UInt64(i)) }
        pos += 8
        return v
    }

    mutating func skip(_ wire: Int) {
        switch wire {
        case 0: _ = varint()
        case 1: pos = min(end, pos + 8)
        case 2: _ = lengthDelimited()
        case 5: pos = min(end, pos + 4)
        default: pos = end
        }
    }

}

func pbString(_ d: [UInt8], _ r: Range<Int>) -> String { String(decoding: d[r], as: UTF8.self) }

@inline(__always) func zigzag(_ n: UInt64) -> Int64 {
    Int64(bitPattern: n >> 1) ^ -Int64(bitPattern: n & 1)
}

/// Rozbalí gzip (pokud je), jinak vrátí data beze změny.
func gunzipIfNeeded(_ d: Data) -> Data? {
    let b = [UInt8](d)
    guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B else { return d }
    let flags = b[3]
    var p = 10
    if flags & 4 != 0, p + 2 <= b.count { p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8) }
    if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
    if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
    if flags & 2 != 0 { p += 2 }
    guard p < b.count - 8 else { return nil }
    let body = Data(b[p..<(b.count - 8)])
    return try? (body as NSData).decompressed(using: .zlib) as Data
}

// MARK: - Model dlaždice
struct TileKey: Hashable {
    let z: Int
    let x: Int
    let y: Int
}

/// Vrstvy kreslení, v pořadí odspodu nahoru.
enum VBucket: Int, CaseIterable {
    case residential, grass, wood, water                     // plochy
    case waterway, rail, track, service, minor, tertiary, secondary, primary, trunk, motorway   // čáry
    var isFill: Bool { rawValue <= VBucket.water.rawValue }
}

struct VLabel {
    let point: CGPoint      // souřadnice v dlaždici (0…extent, y dolů)
    let name: String
    let priority: Int       // 0 město, 1 městečko, 2 vesnice, 3 čtvrť, 4 osada
}

/// Název silnice podél její čáry (souřadnice dlaždice).
struct VRoadLabel {
    let points: [CGPoint]
    let name: String
    let priority: Int       // 0 dálnice/rychlostní, 1 I. třída, 2 II., 3 III., 4 místní, 5 obslužná
}

final class VTile {
    let key: TileKey
    let extent: CGFloat
    let paths: [VBucket: CGPath]
    let labels: [VLabel]
    let roads: [VRoadLabel]
    let fuel: [VLabel]          // čerpací stanice (vrstva poi, class=fuel)
    init(key: TileKey, extent: CGFloat, paths: [VBucket: CGPath], labels: [VLabel], roads: [VRoadLabel], fuel: [VLabel]) {
        self.key = key; self.extent = extent; self.paths = paths; self.labels = labels; self.roads = roads; self.fuel = fuel
    }
}

// MARK: - Dekodér Mapbox Vector Tile (schéma OpenMapTiles)
enum MVTDecoder {
    static let wantedLayers: Set<String> = ["water", "landcover", "landuse", "waterway", "transportation", "place", "transportation_name", "poi"]

    enum Value { case s(String), n(Double) }

    static func decode(_ bytes: [UInt8], key: TileKey) -> VTile {
        var r = PBReader(bytes)
        var paths: [VBucket: CGMutablePath] = [:]
        var labels: [VLabel] = []
        var roads: [VRoadLabel] = []
        var fuel: [VLabel] = []
        var extent: CGFloat = 4096
        while !r.atEnd {
            let (f, w) = r.key()
            if f == 3 && w == 2 {
                let rng = r.lengthDelimited()
                decodeLayer(bytes, rng, &paths, &labels, &roads, &fuel, &extent)
            } else {
                r.skip(w)
            }
        }
        var frozen: [VBucket: CGPath] = [:]
        for (b, p) in paths where !p.isEmpty { frozen[b] = p.copy() }
        return VTile(key: key, extent: extent, paths: frozen, labels: labels, roads: roads, fuel: fuel)
    }

    private static func decodeLayer(_ b: [UInt8], _ rng: Range<Int>, _ paths: inout [VBucket: CGMutablePath],
                                    _ labels: inout [VLabel], _ roads: inout [VRoadLabel], _ fuel: inout [VLabel],
                                    _ extentOut: inout CGFloat) {
        var r = PBReader(b, rng.lowerBound, rng.upperBound)
        var name = ""
        var keys: [String] = []
        var values: [Value] = []
        var features: [Range<Int>] = []
        var extent: CGFloat = 4096
        while !r.atEnd {
            let (f, w) = r.key()
            switch (f, w) {
            case (1, 2): name = pbString(b, r.lengthDelimited())
            case (2, 2): features.append(r.lengthDelimited())
            case (3, 2): keys.append(pbString(b, r.lengthDelimited()))
            case (4, 2): values.append(decodeValue(b, r.lengthDelimited()))
            case (5, 0): extent = CGFloat(r.varint())
            default: r.skip(w)
            }
        }
        guard wantedLayers.contains(name), extent > 0 else { return }
        extentOut = extent

        for fr in features {
            var fReader = PBReader(b, fr.lowerBound, fr.upperBound)
            var tags: [Int] = []
            var type = 0
            var geom: Range<Int>? = nil
            while !fReader.atEnd {
                let (f, w) = fReader.key()
                switch (f, w) {
                case (2, 2):
                    let tr = fReader.lengthDelimited()
                    var tReader = PBReader(b, tr.lowerBound, tr.upperBound)
                    while !tReader.atEnd { tags.append(Int(clamping: tReader.varint())) }
                case (2, 0): tags.append(Int(clamping: fReader.varint()))
                case (3, 0): type = Int(fReader.varint())
                case (4, 2): geom = fReader.lengthDelimited()
                default: fReader.skip(w)
                }
            }
            guard let g = geom else { continue }

            func attr(_ k: String) -> Value? {
                var i = 0
                while i + 1 < tags.count {
                    let ki = tags[i], vi = tags[i + 1]
                    if ki < keys.count, keys[ki] == k, vi < values.count { return values[vi] }
                    i += 2
                }
                return nil
            }
            func str(_ k: String) -> String? { if case .s(let s)? = attr(k) { return s }; return nil }

            let cls = str("class") ?? ""
            switch name {
            case "transportation_name":
                guard type == 2 else { continue }
                let prio: Int
                switch cls {
                case "motorway", "trunk": prio = 0
                case "primary": prio = 1
                case "secondary": prio = 2
                case "tertiary": prio = 3
                case "minor": prio = 4
                case "service": prio = 5
                default: continue
                }
                var label = str("name:cs") ?? str("name:latin") ?? str("name") ?? ""
                if label.isEmpty || prio == 0 { label = str("ref").map { $0.isEmpty ? label : $0 } ?? label }
                if label.isEmpty { continue }
                for line in collectLines(b, g) where line.count >= 2 {
                    roads.append(VRoadLabel(points: line, name: label, priority: prio))
                }
            case "poi":
                guard type == 1, cls == "fuel" else { continue }
                let label = str("name:cs") ?? str("name:latin") ?? str("name") ?? ""
                var pts: [CGPoint] = []
                appendGeometry(b, g, type: 1, path: nil, points: &pts)
                if let p = pts.first { fuel.append(VLabel(point: p, name: label.isEmpty ? "⛽" : label, priority: 0)) }
            case "place":
                guard type == 1 else { continue }
                let prio: Int
                switch cls {
                case "city": prio = 0
                case "town": prio = 1
                case "village": prio = 2
                case "suburb": prio = 3
                case "hamlet": prio = 4
                default: continue
                }
                let label = str("name:cs") ?? str("name:latin") ?? str("name") ?? ""
                if label.isEmpty { continue }
                var pts: [CGPoint] = []
                appendGeometry(b, g, type: 1, path: nil, points: &pts)
                if let p = pts.first { labels.append(VLabel(point: p, name: label, priority: prio)) }
            default:
                guard let bucket = bucketFor(layer: name, cls: cls, type: type) else { continue }
                let path: CGMutablePath
                if let existing = paths[bucket] { path = existing } else { path = CGMutablePath(); paths[bucket] = path }
                var dummy: [CGPoint] = []
                appendGeometry(b, g, type: type, path: path, points: &dummy)
            }
        }
    }

    static func bucketFor(layer: String, cls: String, type: Int) -> VBucket? {
        switch layer {
        case "water": return type == 3 ? .water : nil
        case "landcover":
            guard type == 3 else { return nil }
            switch cls {
            case "wood", "forest": return .wood
            case "grass": return .grass
            default: return nil
            }
        case "landuse":
            guard type == 3 else { return nil }
            switch cls {
            case "residential", "suburb", "neighbourhood", "commercial", "industrial", "retail": return .residential
            default: return nil
            }
        case "waterway": return type == 2 ? .waterway : nil
        case "transportation":
            guard type == 2 else { return nil }
            switch cls {
            case "motorway": return .motorway
            case "trunk": return .trunk
            case "primary": return .primary
            case "secondary": return .secondary
            case "tertiary": return .tertiary
            case "minor": return .minor
            case "service": return .service
            case "track": return .track
            case "rail", "transit": return .rail
            default: return nil
            }
        default: return nil
        }
    }

    private static func decodeValue(_ b: [UInt8], _ rng: Range<Int>) -> Value {
        var r = PBReader(b, rng.lowerBound, rng.upperBound)
        var v: Value = .s("")
        while !r.atEnd {
            let (f, w) = r.key()
            switch (f, w) {
            case (1, 2): v = .s(pbString(b, r.lengthDelimited()))
            case (2, 5): v = .n(Double(Float(bitPattern: r.fixed32())))
            case (3, 1): v = .n(Double(bitPattern: r.fixed64()))
            case (4, 0): v = .n(Double(Int64(bitPattern: r.varint())))
            case (5, 0): v = .n(Double(r.varint()))
            case (6, 0): v = .n(Double(zigzag(r.varint())))
            case (7, 0): v = .n(r.varint() != 0 ? 1 : 0)
            default: r.skip(w)
            }
        }
        return v
    }

    /// Čáry jako pole bodů (pro popisky silnic).
    static func collectLines(_ b: [UInt8], _ rng: Range<Int>) -> [[CGPoint]] {
        var r = PBReader(b, rng.lowerBound, rng.upperBound)
        var x: Int64 = 0, y: Int64 = 0
        var lines: [[CGPoint]] = []
        while !r.atEnd {
            let cmd = r.varint()
            let id = Int(cmd & 7)
            let count = Int(clamping: cmd >> 3)
            guard id == 1 || id == 2 else { if id == 7 { continue } else { break } }
            var i = 0
            while i < count && !r.atEnd {
                x += zigzag(r.varint())
                y += zigzag(r.varint())
                let p = CGPoint(x: CGFloat(x), y: CGFloat(y))
                if id == 1 || lines.isEmpty { lines.append([p]) } else { lines[lines.count - 1].append(p) }
                i += 1
            }
        }
        return lines
    }

    /// Příkazy geometrie MVT: 1 MoveTo, 2 LineTo, 7 ClosePath; parametry zigzag, relativně.
    static func appendGeometry(_ b: [UInt8], _ rng: Range<Int>, type: Int, path: CGMutablePath?, points: inout [CGPoint]) {
        var r = PBReader(b, rng.lowerBound, rng.upperBound)
        var x: Int64 = 0, y: Int64 = 0
        while !r.atEnd {
            let cmd = r.varint()
            let id = Int(cmd & 7)
            let count = Int(clamping: cmd >> 3)
            switch id {
            case 1, 2:
                var i = 0
                while i < count && !r.atEnd {
                    x += zigzag(r.varint())
                    y += zigzag(r.varint())
                    let p = CGPoint(x: CGFloat(x), y: CGFloat(y))
                    if type == 1 { points.append(p) }
                    else if let path = path {
                        if id == 1 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    i += 1
                }
            case 7:
                if type == 3 { path?.closeSubpath() }
            default:
                return
            }
        }
    }
}

// MARK: - Úložiště dlaždic (OpenFreeMap, bez klíče)
final class TileStore {
    static let shared = TileStore()

    let maxZoom = 14
    private let lock = NSLock()
    private var cache: [TileKey: VTile] = [:]
    private var order: [TileKey] = []
    private var queued: Set<TileKey> = []
    private var failedAt: [TileKey: Date] = [:]
    private var template = "https://tiles.openfreemap.org/planet/latest/{z}/{x}/{y}.pbf"
    private let queue = OperationQueue()
    private let session: URLSession
    private let root: URL
    private var dir: URL
    private var sourceKey = "openfreemap"
    private let memLimit = 160
    private var nDownloaded = 0, nDisk = 0, nFailed = 0, nPrefetched = 0
    private var loggedErrors = 0

    private init() {
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "NaviTest-R9/0.3 (iOS; hobby motorcycle navigation)"]
        session = URLSession(configuration: cfg)
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tiles", isDirectory: true)
        dir = root.appendingPathComponent("openfreemap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Starší verze ukládaly dlaždice přímo do tiles/ – přesunout do složky zdroje
        if let old = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for f in old where f.pathExtension == "pbf" {
                try? FileManager.default.moveItem(at: f, to: dir.appendingPathComponent(f.lastPathComponent))
            }
        }
        resolveTemplate()
    }

    var stats: String {
        lock.lock(); defer { lock.unlock() }
        return "paměť \(cache.count) · staženo \(nDownloaded) · disk \(nDisk) · předstaženo \(nPrefetched) · chyby \(nFailed) · fronta \(queued.count)"
    }

    func tile(_ k: TileKey) -> VTile? {
        lock.lock(); defer { lock.unlock() }
        return cache[k]
    }

    /// Požádá o dlaždici. Viditelné mají přednost před předstahováním.
    func request(_ k: TileKey) {
        lock.lock()
        if cache[k] != nil || queued.contains(k) { lock.unlock(); return }
        if let f = failedAt[k], Date().timeIntervalSince(f) < 20 { lock.unlock(); return }
        queued.insert(k)
        lock.unlock()
        let op = BlockOperation { [weak self] in self?.load(k, decode: true) }
        op.queuePriority = .veryHigh
        queue.addOperation(op)
    }

    /// Předstáhne dlaždice podél trasy na disk (bez dekódování do paměti).
    @discardableResult
    func prefetchRoute(_ points: [MKMapPoint]) -> Int {
        guard points.count > 1 else { return 0 }
        var keys = Set<TileKey>()
        for z in [14, 12] {
            let n = 1 << z
            let s = MKMapSize.world.width / Double(n)
            var prev = points[0]
            func add(_ p: MKMapPoint) {
                let tx = Int(p.x / s), ty = Int(p.y / s)
                for dx in -1...1 { for dy in -1...1 {
                    let x = tx + dx, y = ty + dy
                    if x >= 0 && y >= 0 && x < n && y < n { keys.insert(TileKey(z: z, x: x, y: y)) }
                } }
            }
            add(prev)
            for p in points.dropFirst() {
                let d = hypot(p.x - prev.x, p.y - prev.y)
                let steps = max(1, Int(d / (s / 3)))
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    add(MKMapPoint(x: prev.x + (p.x - prev.x) * t, y: prev.y + (p.y - prev.y) * t))
                }
                prev = p
            }
        }
        var added = 0
        lock.lock()
        for k in keys where cache[k] == nil && !queued.contains(k) {
            queued.insert(k)
            added += 1
            let op = BlockOperation { [weak self] in self?.load(k, decode: false) }
            op.queuePriority = .veryLow
            queue.addOperation(op)
        }
        lock.unlock()
        return added
    }

    private func file(_ k: TileKey) -> URL { dir.appendingPathComponent("\(k.z)_\(k.x)_\(k.y).pbf") }

    private func freshOnDisk(_ url: URL) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(m) < 30 * 86400
    }

    private func load(_ k: TileKey, decode: Bool) {
        let url = file(k)
        var bytes: [UInt8]? = nil
        var fromDisk = false
        if freshOnDisk(url), let d = try? Data(contentsOf: url) {
            bytes = [UInt8](d)
            fromDisk = true
        } else if let d = download(k) {
            bytes = [UInt8](d)
            try? d.write(to: url, options: .atomic)
        } else if let d = try? Data(contentsOf: url) {
            // bez internetu: raději starší uložená mapa než prázdné místo
            bytes = [UInt8](d)
            fromDisk = true
        }
        var t: VTile? = nil
        if decode, let b = bytes { t = MVTDecoder.decode(b, key: k) }

        lock.lock()
        queued.remove(k)
        if bytes == nil {
            failedAt[k] = Date()
            nFailed += 1
        } else if decode, let t = t {
            if cache[k] == nil { order.append(k) }
            cache[k] = t
            if fromDisk { nDisk += 1 } else { nDownloaded += 1 }
            while order.count > memLimit {
                let old = order.removeFirst()
                cache.removeValue(forKey: old)
            }
        } else {
            if !fromDisk { nPrefetched += 1 }
        }
        lock.unlock()
    }

    private func download(_ k: TileKey) -> Data? {
        lock.lock(); let tpl = template; lock.unlock()
        let s = tpl.replacingOccurrences(of: "{z}", with: String(k.z))
            .replacingOccurrences(of: "{x}", with: String(k.x))
            .replacingOccurrences(of: "{y}", with: String(k.y))
        guard let url = URL(string: s) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var out: Data? = nil
        let task = session.dataTask(with: url) { [weak self] d, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 || code == 204 || code == 404 {
                // 204/404 = prázdná dlaždice (moře, mimo data) – uložíme jako prázdnou
                out = gunzipIfNeeded(d ?? Data()) ?? Data()
            } else {
                self?.logError("Dlaždice \(k.z)/\(k.x)/\(k.y): HTTP \(code) \(err?.localizedDescription ?? "")")
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 25) == .timedOut { task.cancel(); return nil }
        return out
    }

    private func logError(_ s: String) {
        lock.lock(); loggedErrors += 1; let n = loggedErrors; lock.unlock()
        if n <= 5 || n % 50 == 0 { log("⚠️ \(s)") }
    }

    /// Nastaví zdroj mapových dat. Prázdné = OpenFreeMap. Šablona s {z}/{x}/{y} se použije přímo,
    /// jiná adresa se bere jako TileJSON. Data musí být vektorová ve schématu OpenMapTiles.
    func configure(url raw: String) {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = u.isEmpty ? "openfreemap" : "custom_\(TileStore.hash(u))"
        lock.lock()
        let changed = key != sourceKey
        sourceKey = key
        dir = root.appendingPathComponent(key, isDirectory: true)
        if changed { cache.removeAll(); order.removeAll(); failedAt.removeAll() }
        lock.unlock()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if u.isEmpty {
            if changed { resolveTemplate() }
        } else if u.contains("{z}") && u.contains("{x}") && u.contains("{y}") {
            lock.lock(); template = u; lock.unlock()
            log("🗺️ Vlastní zdroj map: \(u)")
        } else {
            resolveTemplate(from: u)
        }
    }

    private static func hash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 16)
    }

    /// Velikost uložených map v bajtech.
    func diskUsage() -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Smaže všechny uložené mapy.
    func clearDisk() {
        lock.lock(); cache.removeAll(); order.removeAll(); failedAt.removeAll(); lock.unlock()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("🗑️ Uložené mapy smazány")
    }

    /// Čerpací stanice z mapových dat v okolí (jen z paměti / disku, bez internetu). Záloha pro Apple hledání.
    func fuelStations(near c: CLLocationCoordinate2D, tilesAround: Int = 2) -> [(name: String, coordinate: CLLocationCoordinate2D)] {
        let z = maxZoom
        let n = 1 << z
        let s = MKMapSize.world.width / Double(n)
        let p = MKMapPoint(c)
        let cx = Int(p.x / s), cy = Int(p.y / s)
        var out: [(String, CLLocationCoordinate2D)] = []
        for x in (cx - tilesAround)...(cx + tilesAround) {
            for y in (cy - tilesAround)...(cy + tilesAround) where x >= 0 && y >= 0 && x < n && y < n {
                let k = TileKey(z: z, x: x, y: y)
                var t = tile(k)
                if t == nil, let d = try? Data(contentsOf: file(k)) { t = MVTDecoder.decode([UInt8](d), key: k) }
                guard let tile = t else { continue }
                for f in tile.fuel {
                    let mp = MKMapPoint(x: Double(x) * s + Double(f.point.x) / Double(tile.extent) * s,
                                        y: Double(y) * s + Double(f.point.y) / Double(tile.extent) * s)
                    out.append((f.name, mp.coordinate))
                }
            }
        }
        return out
    }

    private func resolveTemplate(from custom: String? = nil) {
        guard let url = URL(string: custom ?? "https://tiles.openfreemap.org/planet") else { return }
        session.dataTask(with: url) { [weak self] d, _, _ in
            guard let self = self, let d = d,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let tiles = obj["tiles"] as? [String], let t = tiles.first else {
                log("ℹ️ Mapové dlaždice: používám adresu „latest“")
                return
            }
            self.lock.lock(); self.template = t; self.lock.unlock()
            log("🗺️ Mapové dlaždice: \(t)")
        }.resume()
    }
}

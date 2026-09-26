import Foundation
import MapKit

struct RouteManeuver {
    let at: Double                       // metry od začátku trasy
    let icon: UInt8
    let road: String
    let text: String
    let coordinate: CLLocationCoordinate2D
    var street: String = ""          // čistý název ulice pro hlas (může být prázdný)
    var rbExit: Int = 0
    var rbAround: Double = 180
}

/// Trasa z Apple Map převedená na jednu lomenou čáru + seznam manévrů na ní.
final class NavRoute {
    let destinationName: String
    let points: [MKMapPoint]
    let cum: [Double]
    let maneuvers: [RouteManeuver]
    let total: Double
    let expectedTime: TimeInterval

    /// Průjezdní body trasy (vzdálenost od začátku, souřadnice, název).
    let vias: [(at: Double, coordinate: CLLocationCoordinate2D, name: String)]

    convenience init(route: MKRoute, destinationName: String) {
        self.init(routes: [route], names: [destinationName])
    }

    /// Trasa z více úseků (A → průjezdní body → cíl). `names` = název konce každého úseku.
    init(routes: [MKRoute], names: [String]) {
        self.destinationName = names.last ?? ""
        struct StepRef { let leg: Int; let text: String; let start: Int }
        var pts: [MKMapPoint] = []
        var refs: [StepRef] = []
        var legEnd: [Int] = []
        for (li, route) in routes.enumerated() {
            for step in route.steps {
                let n = step.polyline.pointCount
                let p = step.polyline.points()
                var start = max(0, pts.count - 1)
                if n > 0 {
                    if let last = pts.last, last.distance(to: p[0]) < 0.5 { start = pts.count - 1 } else { start = pts.count }
                    for k in 0..<n {
                        let mp = p[k]
                        if let last = pts.last, last.distance(to: mp) < 0.5 { continue }
                        pts.append(mp)
                    }
                }
                refs.append(StepRef(leg: li, text: step.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                                    start: min(start, max(0, pts.count - 1))))
            }
            legEnd.append(max(0, pts.count - 1))
        }
        if pts.count < 2 {
            pts = []
            for route in routes {
                let n = route.polyline.pointCount, p = route.polyline.points()
                for k in 0..<n { pts.append(p[k]) }
            }
            refs = refs.map { StepRef(leg: $0.leg, text: $0.text, start: 0) }
            legEnd = legEnd.map { _ in max(0, pts.count - 1) }
        }
        if pts.count < 2, let only = pts.first { pts.append(only) }
        if pts.isEmpty { pts = [MKMapPoint(x: 0, y: 0), MKMapPoint(x: 0, y: 0)] }
        var c: [Double] = [0]
        for i in 1..<pts.count { c.append(c[i - 1] + pts[i - 1].distance(to: pts[i])) }
        points = pts
        cum = c
        total = c.last ?? 0
        expectedTime = routes.reduce(0) { $0 + $1.expectedTravelTime }

        var man: [RouteManeuver] = []
        var viaList: [(at: Double, coordinate: CLLocationCoordinate2D, name: String)] = []
        let lastLeg = routes.count - 1
        for (i, ref) in refs.enumerated() {
            let lastOfLeg = i + 1 >= refs.count || refs[i + 1].leg != ref.leg
            let finalLeg = ref.leg == lastLeg
            let legName = ref.leg < names.count ? names[ref.leg] : destinationName
            if ref.text.isEmpty {
                // úsek bez textu na konci → průjezdní bod doplníme sami
                if lastOfLeg && !finalLeg {
                    let idx = min(legEnd[ref.leg], pts.count - 1)
                    man.append(RouteManeuver(at: c[idx], icon: 3, road: legName, text: legName, coordinate: pts[idx].coordinate))
                    viaList.append((c[idx], pts[idx].coordinate, legName))
                }
                continue
            }
            let text = ref.text
            // MapKit: pokyn kroku platí na jeho KONCI (= začátek dalšího kroku), u posledního na konci úseku
            let endIdx = lastOfLeg ? legEnd[ref.leg] : refs[i + 1].start
            let idx = min(max(0, endIdx), pts.count - 1)
            let at = c[idx]
            let delta = NavRoute.turnDelta(points: pts, cum: c, at: at)
            var icon = NavRoute.classify(text, delta: delta, isLast: lastOfLeg)
            var rbExit = 0
            var rbAround = 180.0
            if TurnIcon.isRoundabout(icon) {
                // Směr výjezdu: 1) z textu pokynu, 2) z tvaru trasy – tětiva od vjezdu k bodu ~200 m dál
                let tl = text.lowercased()
                var around: Double
                if tl.contains("doleva") || tl.contains("vlevo") || tl.contains(" left") {
                    around = 270
                } else if tl.contains("doprava") || tl.contains("vpravo") || tl.contains(" right") {
                    around = 90
                } else if tl.contains("rovně") || tl.contains("pokračujte") || tl.contains("straight") || tl.contains("continue") {
                    around = 180
                } else {
                    let inB = NavRoute.bearing(NavRoute.pointAt(points: pts, cum: c, d: at - 40),
                                               NavRoute.pointAt(points: pts, cum: c, d: at))
                    let outB = NavRoute.bearing(NavRoute.pointAt(points: pts, cum: c, d: at),
                                                NavRoute.pointAt(points: pts, cum: c, d: at + 200))
                    var d = outB - inB
                    while d > 180 { d -= 360 }
                    while d < -180 { d += 360 }
                    around = 180 - d
                    if around <= 0 { around += 360 }
                    if around > 360 { around -= 360 }
                }
                rbAround = around
                icon = TurnIcon.roundabout(around: around)
                rbExit = NavRoute.exitNumber(text)
            }
            var arrival = TurnIcon.isArrival(icon)
            if lastOfLeg && !finalLeg {
                // konec úseku před dalším = průjezdní bod (Garmin ikony 3/4/5)
                if !arrival { icon = 3; arrival = true } else if icon <= 2 { icon += 3 }
                viaList.append((at, pts[idx].coordinate, legName))
            }
            man.append(RouteManeuver(at: at, icon: icon, road: arrival ? legName : NavRoute.roadName(text), text: text,
                                     coordinate: pts[idx].coordinate, street: arrival ? "" : NavRoute.streetName(text),
                                     rbExit: rbExit, rbAround: rbAround))
        }
        if man.last.map({ $0.icon > 2 }) ?? true {
            man.append(RouteManeuver(at: total, icon: TurnIcon.arriving, road: destinationName, text: T("Destination"),
                                     coordinate: pts[pts.count - 1].coordinate))
        }
        man.sort { $0.at < $1.at }
        vias = viaList
        maneuvers = man
    }

    // MARK: Geometrie
    /// Index posledního bodu, jehož kumulativní vzdálenost je <= d.
    func index(for d: Double) -> Int {
        var lo = 0, hi = cum.count - 1
        if d <= 0 { return 0 }
        if d >= cum[hi] { return max(0, hi - 1) }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cum[mid] <= d { lo = mid } else { hi = mid - 1 }
        }
        return min(lo, cum.count - 2)
    }

    func point(at d: Double) -> MKMapPoint {
        NavRoute.pointAt(points: points, cum: cum, d: d)
    }

    func bearing(at d: Double) -> Double {
        NavRoute.bearing(point(at: d - 15), point(at: d + 15))
    }

    func coords(from a: Double, to b: Double) -> [CLLocationCoordinate2D] {
        let s = max(0, a), e = min(total, b)
        if e <= s { return [] }
        var out = [point(at: s).coordinate]
        var i = index(for: s) + 1
        while i < cum.count && cum[i] < e { out.append(points[i].coordinate); i += 1 }
        out.append(point(at: e).coordinate)
        return out
    }

    static func pointAt(points: [MKMapPoint], cum: [Double], d: Double) -> MKMapPoint {
        guard points.count > 1 else { return points.first ?? MKMapPoint(x: 0, y: 0) }
        let dd = min(max(0, d), cum[cum.count - 1])
        var lo = 0, hi = cum.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if cum[mid] <= dd { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let seg = cum[hi] - cum[lo]
        let t = seg > 0 ? (dd - cum[lo]) / seg : 0
        return MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    static func bearing(_ a: MKMapPoint, _ b: MKMapPoint) -> Double {
        let p1 = a.coordinate, p2 = b.coordinate
        let φ1 = p1.latitude * .pi / 180, φ2 = p2.latitude * .pi / 180
        let Δλ = (p2.longitude - p1.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Úhel odbočení v místě manévru (+ doprava, − doleva).
    static func turnDelta(points: [MKMapPoint], cum: [Double], at: Double) -> Double {
        let before = pointAt(points: points, cum: cum, d: at - 25)
        let here = pointAt(points: points, cum: cum, d: at)
        let after = pointAt(points: points, cum: cum, d: at + 25)
        if before.distance(to: here) < 3 || here.distance(to: after) < 3 { return 0 }
        var d = bearing(here, after) - bearing(before, here)
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    // MARK: Text pokynů → ikona a název ulice
    static func classify(_ text: String, delta: Double, isLast: Bool) -> UInt8 {
        let t = text.lowercased()
        let left = t.contains("vlevo") || t.contains("doleva") || t.contains("left")
        let right = t.contains("vpravo") || t.contains("doprava") || t.contains("right")
        if isLast || t.contains("cíl") || t.contains("destinac") || t.contains("dorazíte") || t.contains("arrive") || t.contains("destination") {
            return left ? TurnIcon.arrivingL : (right ? TurnIcon.arrivingR : TurnIcon.arriving)
        }
        if t.contains("kruhov") || t.contains("roundabout") { return TurnIcon.roundabout }
        if t.contains("otoč") || t.contains("u-turn") || t.contains("make a u") { return TurnIcon.uturnL }
        let goLeft = left ? true : (right ? false : delta < 0)
        if t.contains("sjeď") || t.contains("sjezd") || t.contains("výjezd") || t.contains("exit") || t.contains("ramp") {
            return goLeft ? TurnIcon.exitL : TurnIcon.exitR
        }
        if t.contains("držte") || t.contains("keep") || t.contains("mírně") || t.contains("slight") || t.contains("bear") || (t.contains("pokrač") && (left || right)) {
            return goLeft ? TurnIcon.keepL : TurnIcon.keepR
        }
        let a = abs(delta)
        if left || right {
            if a > 135 { return goLeft ? TurnIcon.sharpL : TurnIcon.sharpR }
            return goLeft ? TurnIcon.turnL : TurnIcon.turnR
        }
        if a < 20 { return TurnIcon.straight }
        if a < 45 { return goLeft ? TurnIcon.keepL : TurnIcon.keepR }
        if a < 135 { return goLeft ? TurnIcon.turnL : TurnIcon.turnR }
        if a < 170 { return goLeft ? TurnIcon.sharpL : TurnIcon.sharpR }
        return TurnIcon.uturnL
    }

    /// Číslo výjezdu z kruháče: „2. výjezdem“, „prvním výjezdem“, „take the 2nd exit“, „second exit“ → číslo, jinak 0.
    static func exitNumber(_ text: String) -> Int {
        let t = text.lowercased()
        if let r = t.range(of: #"\d+\.\s*výjezd"#, options: .regularExpression)
            ?? t.range(of: #"\d+(st|nd|rd|th)\s+exit"#, options: .regularExpression) {
            return Int(t[r].prefix { $0.isNumber }) ?? 0
        }
        let words: [(String, Int)] = [
            ("první", 1), ("druh", 2), ("třetí", 3), ("čtvrt", 4), ("pát", 5), ("šest", 6),
            ("first exit", 1), ("second exit", 2), ("third exit", 3), ("fourth exit", 4), ("fifth exit", 5), ("sixth exit", 6),
        ]
        if t.contains("výjezd") || t.contains("exit") {
            for (w, n) in words where t.contains(w) { return n }
        }
        return 0
    }

    /// Čistý název ulice („… na Nábřeží“ / „… onto Main St“), jinak prázdný řetězec.
    static func streetName(_ text: String) -> String {
        for sep in [" na ", " onto ", " on "] {
            if let r = text.range(of: sep, options: .backwards) {
                var s = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                for p in ["ulici ", "silnici ", "ulice "] where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)) }
                if let comma = s.firstIndex(of: ",") { s = String(s[..<comma]) }
                return s
            }
        }
        return ""
    }

    static func roadName(_ text: String) -> String {
        var prefix = ""
        if let r = text.range(of: #"\d+\.\s*výjezd"#, options: .regularExpression) {
            prefix = String(text[r]) + " · "
        }
        for sep in [" na ", " onto ", " on "] {
            if let r = text.range(of: sep, options: .backwards) {
                var s = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                for p in ["ulici ", "silnici ", "ulice "] where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)) }
                if !s.isEmpty { return prefix + s }
            }
        }
        return prefix.isEmpty ? text : prefix + text
    }
}

/// Stav navigace. `update` volá hlavní vlákno (poloha), `snapshot` čte vlákno spojení s motorkou.
final class Navigator {
    private let lock = NSLock()
    private var route: NavRoute?
    private var matchedSeg = 0
    private var along: Double = 0
    private var matchDist: Double = .infinity
    private var offCount = 0
    private var lastLocation: CLLocation?
    private var fixTime = Date.distantPast
    private var heading: Double = 0
    private var arrivedAt: Date?
    private var lastReroute = Date.distantPast
    private var _generation = 0

    /// Zvyšuje se s každou novou trasou (i přepočtem) – podle toho se přístrojovce posílá start trasy.
    var routeGeneration: Int { lock.lock(); defer { lock.unlock() }; return _generation }

    /// Volá se na hlavním vlákně, když je potřeba přepočítat trasu (sjetí z trasy).
    var onReroute: ((CLLocation) -> Void)?
    /// Rychlostní limit v místě trasy (z asistence jezdce), 0 = neznámý.
    var limitAt: ((Double) -> Int)?

    var hasRoute: Bool { lock.lock(); defer { lock.unlock() }; return route != nil }
    var location: CLLocation? { lock.lock(); defer { lock.unlock() }; return lastLocation }

    func setRoute(_ r: NavRoute?) {
        lock.lock(); defer { lock.unlock() }
        route = r
        if r != nil { _generation += 1 }
        matchedSeg = 0; along = 0; offCount = 0; arrivedAt = nil; matchDist = .infinity
        if let loc = lastLocation, r != nil {
            let m = match(loc, full: true)
            matchedSeg = m.seg; along = m.along; matchDist = m.dist
        }
    }

    func update(_ loc: CLLocation) {
        lock.lock(); defer { lock.unlock() }
        lastLocation = loc
        fixTime = Date()
        if loc.speed > 2, loc.course >= 0 { heading = loc.course }
        guard let r = route else { return }
        var m = match(loc, full: false)
        if m.dist > 80 {
            let f = match(loc, full: true)
            if f.dist < m.dist { m = f }
        }
        matchedSeg = m.seg; along = m.along; matchDist = m.dist
        if !(loc.speed > 2 && loc.course >= 0) { heading = r.bearing(at: along) }

        let threshold = max(40, loc.horizontalAccuracy * 1.5)
        if m.dist > threshold && loc.horizontalAccuracy > 0 && loc.horizontalAccuracy < 60 { offCount += 1 } else { offCount = 0 }
        if offCount >= 3 && Date().timeIntervalSince(lastReroute) > 15 && arrivedAt == nil {
            lastReroute = Date()
            offCount = 0
            let cb = onReroute
            DispatchQueue.main.async { cb?(loc) }
        }
        if arrivedAt == nil && r.total - along < 25 && m.dist < 60 { arrivedAt = Date() }
    }

    private func match(_ loc: CLLocation, full: Bool) -> (seg: Int, along: Double, dist: Double) {
        guard let r = route, r.points.count >= 2 else { return (0, 0, .infinity) }
        let p = MKMapPoint(loc.coordinate)
        let last = r.points.count - 2
        let lo = full ? 0 : max(0, matchedSeg - 3)
        let hi = full ? last : min(last, matchedSeg + 150)
        var best = (seg: matchedSeg, along: along, dist: Double.infinity)
        if hi < lo { return best }
        for i in lo...hi {
            let a = r.points[i], b = r.points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
            t = min(1, max(0, t))
            let q = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = q.distance(to: p)
            if d < best.dist { best = (i, r.cum[i] + a.distance(to: q), d) }
        }
        return best
    }

    /// Kolik průjezdních bodů už je za námi.
    func passedVias() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let r = route else { return 0 }
        return r.vias.filter { $0.at <= along + 15 }.count
    }

    /// Kolik průjezdních bodů ještě zbývá (pro přístrojovku, zpráva 18).
    func remainingVias() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let r = route else { return 0 }
        return r.vias.filter { $0.at > along + 15 }.count
    }

    /// Celý seznam odboček trasy pro přístrojovku (globální index = pořadí), vzdálenost = úsek od předchozí odbočky.
    func turnList() -> [TurnItem] {
        lock.lock(); defer { lock.unlock() }
        guard let r = route else { return [] }
        var prev = 0.0
        return r.maneuvers.map { m in
            let leg = max(0, m.at - prev)
            prev = m.at
            return TurnItem(icon: m.icon, leg: leg, label: m.street.isEmpty ? m.road : m.street)
        }
    }

    /// Posun bodu o `dist` metrů ve směru `heading` (pro dopočet polohy mezi údaji z GPS).
    private func moved(_ c: CLLocationCoordinate2D, heading: Double, dist: Double) -> CLLocationCoordinate2D {
        let mpm = MKMetersPerMapPointAtLatitude(c.latitude)
        let h = heading * .pi / 180
        var p = MKMapPoint(c)
        p.x += sin(h) * dist / mpm
        p.y -= cos(h) * dist / mpm
        return p.coordinate
    }

    /// Snímek navigace. Poloha se mezi údaji z GPS (~1× za s) dopočítává podle rychlosti,
    /// takže mapa v motorce se pohybuje plynule při jakémkoli počtu snímků.
    func snapshot() -> NavSnapshot? {
        lock.lock(); defer { lock.unlock() }
        let dt = min(2.0, max(0, Date().timeIntervalSince(fixTime)))
        let spd = max(0, lastLocation?.speed ?? 0)
        guard let r = route else {
            // Volná jízda: jen poloha a směr, žádné pokyny
            guard let loc = lastLocation else { return nil }
            var s = NavSnapshot()
            s.guiding = false
            s.position = spd > 1.5 ? moved(loc.coordinate, heading: heading, dist: spd * dt) : loc.coordinate
            s.heading = heading
            return s
        }
        let onRoute = matchDist < 40
        let a = (onRoute && spd > 1.0 && arrivedAt == nil) ? min(r.total, along + spd * dt) : along
        var s = NavSnapshot()
        let idx = r.maneuvers.firstIndex { $0.at > a + 3 } ?? (r.maneuvers.count - 1)
        let m = r.maneuvers[idx]
        s.icon = m.icon
        s.toNext = max(0, m.at - a)
        s.road = m.road
        s.text = m.text
        s.remaining = max(0, r.total - a)
        let secs = r.total > 0 ? r.expectedTime * s.remaining / r.total : 0
        s.minutesLeft = Int((secs / 60).rounded(.up))
        (s.etaHour, s.etaMinute) = etaComponents(secondsFromNow: secs)
        s.currentRoad = idx > 0 ? r.maneuvers[idx - 1].road : ""
        s.upcoming = r.maneuvers[idx...].prefix(5).map { UpcomingItem(icon: $0.icon, dist: max(0, $0.at - a), text: $0.text) }
        s.maneuverIndex = idx
        s.rbExit = m.rbExit
        s.rbAround = m.rbAround
        s.street = m.street
        if idx + 1 < r.maneuvers.count {
            let nx = r.maneuvers[idx + 1]
            s.nextIcon = nx.icon
            s.nextGap = nx.at - m.at
        }
        if let loc = lastLocation {
            s.position = onRoute ? r.point(at: a).coordinate : loc.coordinate
        }
        s.heading = (onRoute && spd > 1.0) ? r.bearing(at: a) : heading
        s.routeAhead = r.coords(from: a, to: r.total)   // celá zbývající trasa
        s.routeBehind = r.coords(from: a - 400, to: a)
        s.maneuverPoint = m.coordinate
        s.destination = r.points.last?.coordinate
        s.along = a
        s.waypoints = r.vias.filter { $0.at > a + 10 }.map { $0.coordinate }
        if let f = limitAt { s.speedLimit = Float(f(a)) }
        if arrivedAt != nil {
            s.arrived = true
            s.icon = r.maneuvers.last?.icon ?? TurnIcon.arriving
            s.toNext = 0
            s.remaining = 0
            s.minutesLeft = 0
        }
        return s
    }
}

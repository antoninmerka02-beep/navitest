import Foundation
import MapKit

struct RouteManeuver {
    let at: Double                       // metry od začátku trasy
    let icon: UInt8
    let road: String
    let text: String
    let coordinate: CLLocationCoordinate2D
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

    init(route: MKRoute, destinationName: String) {
        self.destinationName = destinationName
        var pts: [MKMapPoint] = []
        var stepStart: [Int] = []
        for step in route.steps {
            let n = step.polyline.pointCount
            let p = step.polyline.points()
            if n == 0 { stepStart.append(max(0, pts.count - 1)); continue }
            if let last = pts.last, last.distance(to: p[0]) < 0.5 { stepStart.append(pts.count - 1) }
            else { stepStart.append(pts.count) }
            for k in 0..<n {
                let mp = p[k]
                if let last = pts.last, last.distance(to: mp) < 0.5 { continue }
                pts.append(mp)
            }
        }
        if pts.count < 2 {
            pts = []
            let n = route.polyline.pointCount, p = route.polyline.points()
            for k in 0..<n { pts.append(p[k]) }
            stepStart = route.steps.map { _ in 0 }
        }
        if pts.count < 2, let only = pts.first { pts.append(only) }
        var c: [Double] = [0]
        for i in 1..<pts.count { c.append(c[i - 1] + pts[i - 1].distance(to: pts[i])) }
        points = pts
        cum = c
        total = c.last ?? 0
        expectedTime = route.expectedTravelTime

        var man: [RouteManeuver] = []
        let steps = route.steps
        for (i, step) in steps.enumerated() where i > 0 {
            let text = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let idx = min(stepStart[i], pts.count - 1)
            let at = c[idx]
            let isLast = i == steps.count - 1
            let delta = NavRoute.turnDelta(points: pts, cum: c, at: at)
            var icon = NavRoute.classify(text, delta: delta, isLast: isLast)
            var rbExit = 0
            var rbAround = 180.0
            if TurnIcon.isRoundabout(icon) {
                // Směr výjezdu: příjezd (posledních 30 m) vs. odjezd (80–130 m za vjezdem)
                let inB = NavRoute.bearing(NavRoute.pointAt(points: pts, cum: c, d: at - 30),
                                           NavRoute.pointAt(points: pts, cum: c, d: at))
                let outB = NavRoute.bearing(NavRoute.pointAt(points: pts, cum: c, d: at + 80),
                                            NavRoute.pointAt(points: pts, cum: c, d: at + 130))
                var d = outB - inB
                while d > 180 { d -= 360 }
                while d < -180 { d += 360 }
                var around = 180 - d
                if around <= 0 { around += 360 }
                if around > 360 { around -= 360 }
                rbAround = around
                icon = TurnIcon.roundabout(around: around)
                rbExit = NavRoute.exitNumber(text)
            }
            man.append(RouteManeuver(at: at, icon: icon, road: NavRoute.roadName(text), text: text,
                                     coordinate: pts[idx].coordinate, rbExit: rbExit, rbAround: rbAround))
        }
        if man.last.map({ $0.icon > 2 }) ?? true {
            man.append(RouteManeuver(at: total, icon: TurnIcon.arriving, road: destinationName, text: "Cíl",
                                     coordinate: pts[pts.count - 1].coordinate))
        }
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
        if t.contains("držte") || t.contains("keep") || t.contains("mírně") || t.contains("slight") || (t.contains("pokrač") && (left || right)) {
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

    /// „… 2. výjezdem …“ → 2
    static func exitNumber(_ text: String) -> Int {
        guard let r = text.range(of: #"\d+\.\s*výjezd"#, options: .regularExpression) else { return 0 }
        let digits = text[r].prefix { $0.isNumber }
        return Int(digits) ?? 0
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
    private var heading: Double = 0
    private var arrivedAt: Date?
    private var lastReroute = Date.distantPast
    private var _generation = 0

    /// Zvyšuje se s každou novou trasou (i přepočtem) – podle toho se přístrojovce posílá start trasy.
    var routeGeneration: Int { lock.lock(); defer { lock.unlock() }; return _generation }

    /// Volá se na hlavním vlákně, když je potřeba přepočítat trasu (sjetí z trasy).
    var onReroute: ((CLLocation) -> Void)?

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

    func snapshot() -> NavSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let r = route else {
            // Volná jízda: jen poloha a směr, žádné pokyny
            guard let loc = lastLocation else { return nil }
            var s = NavSnapshot()
            s.guiding = false
            s.position = loc.coordinate
            s.heading = heading
            return s
        }
        var s = NavSnapshot()
        let idx = r.maneuvers.firstIndex { $0.at > along + 3 } ?? (r.maneuvers.count - 1)
        let m = r.maneuvers[idx]
        s.icon = m.icon
        s.toNext = max(0, m.at - along)
        s.road = m.road
        s.text = m.text
        s.remaining = max(0, r.total - along)
        let secs = r.total > 0 ? r.expectedTime * s.remaining / r.total : 0
        s.minutesLeft = Int((secs / 60).rounded(.up))
        (s.etaHour, s.etaMinute) = etaComponents(secondsFromNow: secs)
        s.currentRoad = idx > 0 ? r.maneuvers[idx - 1].road : ""
        s.upcoming = r.maneuvers[idx...].prefix(5).map { UpcomingItem(icon: $0.icon, dist: max(0, $0.at - along), text: $0.text) }
        s.maneuverIndex = idx
        s.rbExit = m.rbExit
        s.rbAround = m.rbAround
        if let loc = lastLocation {
            s.position = matchDist < 40 ? r.point(at: along).coordinate : loc.coordinate
        }
        s.heading = heading
        s.routeAhead = r.coords(from: along, to: r.total)   // celá zbývající trasa
        s.routeBehind = r.coords(from: along - 400, to: along)
        s.maneuverPoint = m.coordinate
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

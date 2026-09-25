import Foundation
import CoreGraphics
import CoreText
import ImageIO
import MapKit

enum MapSource: String, CaseIterable, Identifiable, Codable {
    case vector, own, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vector: return T("OSM map")
        case .own: return T("Route only")
        case .apple: return "Apple"
        }
    }
}

struct RenderParams {
    var width = 480
    var height = 240
    var quality = 0.55
    var mpp = 3.0            // metrů na pixel (zoom)
    var northUp = false
    var dark = true
    var mapSource: MapSource = .vector
    var turnBox = true
    var threeD = false
    var streetNames = true
    var note = ""
}

/// Kreslí snímek čistě na CPU (Core Graphics) – funguje i se zamčeným telefonem.
final class FrameRenderer {
    private let cs = CGColorSpaceCreateDeviceRGB()
    private let vector = VectorMapRenderer()
    private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func render(frame n: Int, nav: NavSnapshot?, p: RenderParams, snap: MapSnapshotProvider.Snap?) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: p.width, height: p.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        if let nav = nav, let pos = nav.position {
            drawMap(ctx, nav: nav, pos: pos, p: p, snap: p.mapSource == .apple ? snap : nil, frame: n)
        } else {
            drawTestPattern(ctx, frame: n, nav: nav, p: p)
        }
        if let nav = nav, nav.guiding, p.turnBox {
            drawTurnBox(ctx, nav: nav, H: CGFloat(p.height))
        }
        guard let img = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: p.quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](data as Data)
    }

    // MARK: Mapa
    private func drawMap(_ ctx: CGContext, nav: NavSnapshot, pos: CLLocationCoordinate2D, p: RenderParams,
                         snap: MapSnapshotProvider.Snap?, frame n: Int) {
        let W = CGFloat(p.width), H = CGFloat(p.height)
        ctx.setFillColor(VStyle.background(dark: p.dark))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        let anchor = CGPoint(x: W / 2, y: 62)
        let theta = p.northUp ? 0 : CGFloat(nav.heading * .pi / 180)

        // Převod souřadnic do lokálních pixelů (sever nahoru, y nahoru, poloha = 0,0)
        var local: (CLLocationCoordinate2D) -> CGPoint
        var zoomScale: CGFloat = 1
        if let s = snap {
            let p0 = s.snapshot.point(for: pos)
            local = { c in
                let q = s.snapshot.point(for: c)
                return CGPoint(x: q.x - p0.x, y: p0.y - q.y)
            }
            // Než dorazí nový snímek po změně zoomu, aspoň ho roztáhneme
            zoomScale = CGFloat(s.mpp / p.mpp)
        } else {
            let a = MKMapPoint(pos)
            let k = MKMetersPerMapPointAtLatitude(pos.latitude) / p.mpp
            local = { c in
                let b = MKMapPoint(c)
                return CGPoint(x: (b.x - a.x) * k, y: -(b.y - a.y) * k)
            }
        }

        var result = VMapResult()
        var toScreen: (CGPoint) -> CGPoint?
        var arrowAt = anchor
        let use3D = p.threeD && snap == nil

        if use3D {
            // ---- 3D: perspektiva, poloha dole uprostřed
            let persp = Perspective(W: W, H: H, anchorY: 52, headingRad: p.northUp ? 0 : CGFloat(nav.heading * .pi / 180))
            toScreen = { persp.project($0) }
            arrowAt = CGPoint(x: W / 2, y: 52)
            if p.mapSource == .vector {
                result = vector.draw3D(ctx, pos: pos, mpp: p.mpp, persp: persp, dark: p.dark, streetNames: p.streetNames)
            }
            let behind = CGMutablePath()
            persp.add(decimate(nav.routeBehind.map(local)), closed: false, to: behind)
            strokePath(ctx, behind, color: CGColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 0.9), width: 8)
            let ahead = CGMutablePath()
            persp.add(decimate(nav.routeAhead.map(local)), closed: false, to: ahead)
            strokePath(ctx, ahead, color: CGColor(red: 0.0, green: 0.2, blue: 0.25, alpha: 1), width: 13)
            strokePath(ctx, ahead, color: CGColor(red: 0.0, green: 0.85, blue: 0.95, alpha: 1), width: 8)
            if let mp = nav.maneuverPoint, nav.guiding, let q = persp.project(local(mp)) {
                ctx.setFillColor(CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: q.x - 7, y: q.y - 7, width: 14, height: 14))
            }
            // „mlha“ do dálky – vzdálené detaily splynou a obraz je klidnější
            let bg = VStyle.background(dark: p.dark)
            if let g = CGGradient(colorsSpace: cs, colors: [bg.copy(alpha: 0)!, bg.copy(alpha: 0.9)!] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H * 0.55), end: CGPoint(x: 0, y: H), options: [.drawsAfterEndLocation])
            }
        } else {
        // ---- 2D
        let c2 = cos(theta), s2 = sin(theta)
        let zs = zoomScale
        toScreen = { q in CGPoint(x: anchor.x + (q.x * c2 - q.y * s2) * zs, y: anchor.y + (q.x * s2 + q.y * c2) * zs) }
        ctx.saveGState()
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.rotate(by: theta)
        ctx.scaleBy(x: zoomScale, y: zoomScale)
        if let s = snap {
            // Kreslíme v bodech snímku (ne v pixelech) – funguje pro jakékoli měřítko obrázku.
            let p0 = s.snapshot.point(for: pos)
            let sz = s.snapshot.image.size
            ctx.draw(s.image, in: CGRect(x: -p0.x, y: p0.y - sz.height, width: sz.width, height: sz.height))
        } else if p.mapSource == .vector {
            let radius = hypot(W / 2, max(anchor.y, H - anchor.y)) + 24
            result = vector.draw(ctx, pos: pos, mpp: p.mpp, radiusPx: radius, dark: p.dark, streetNames: p.streetNames)
        }
        // ujetá část trasy
        stroke(ctx, nav.routeBehind.map(local), color: CGColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 0.9), width: 8 / zoomScale)
        // trasa před námi: tmavý okraj + tyrkysová
        let ahead = nav.routeAhead.map(local)
        stroke(ctx, ahead, color: CGColor(red: 0.0, green: 0.2, blue: 0.25, alpha: 1), width: 13 / zoomScale)
        stroke(ctx, ahead, color: CGColor(red: 0.0, green: 0.85, blue: 0.95, alpha: 1), width: 8 / zoomScale)
        if let mp = nav.maneuverPoint, nav.guiding {
            let q = local(mp)
            let r = 7 / zoomScale
            ctx.setFillColor(CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.restoreGState()
        }

        // Cílová vlajka (šachovnice) – malá, ať nepřekáží
        if nav.guiding, let dest = nav.destination, let q = toScreen(local(dest)),
           q.x > -20, q.x < W + 20, q.y > -20, q.y < H + 30 {
            drawFinishFlag(ctx, at: q)
        }

        // Popisky: nejdřív ulice podél silnic, pak obce (svisle); nepřekrývají se
        var taken: [CGRect] = [
            CGRect(x: 0, y: H - 72, width: 180, height: 72),                  // box se šipkou
            CGRect(x: arrowAt.x - 30, y: arrowAt.y - 30, width: 60, height: 60), // naše poloha
            CGRect(x: W - 70, y: 0, width: 70, height: 70),                   // limit přístrojovky
            CGRect(x: 0, y: 40, width: 60, height: 120),                      // tlačítka +/− přístrojovky
        ]
        drawRoadLabels(ctx, result.roads, toScreen: toScreen, W: W, H: H, dark: p.dark, taken: &taken)
        drawLabels(ctx, result.places, toScreen: toScreen, W: W, H: H, dark: p.dark, taken: &taken)

        // šipka polohy
        ctx.saveGState()
        ctx.translateBy(x: arrowAt.x, y: arrowAt.y)
        if use3D { ctx.scaleBy(x: 1, y: 0.8) }
        if p.northUp { ctx.rotate(by: -CGFloat(nav.heading * .pi / 180)) }
        ctx.setFillColor(CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1))
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: 0, y: 18))
        ctx.addLine(to: CGPoint(x: -12, y: -14))
        ctx.addLine(to: CGPoint(x: 0, y: -7))
        ctx.addLine(to: CGPoint(x: 12, y: -14))
        ctx.closePath()
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        let fg = p.dark ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.7) : CGColor(red: 0, green: 0, blue: 0, alpha: 0.7)
        let src = p.mapSource == .apple ? (snap != nil ? "Apple" : "Apple čeká") : (p.mapSource == .vector ? "© OpenStreetMap" : "trasa")
        text(ctx, "#\(n) \(timeFmt.string(from: Date())) · \(src)", x: 6, y: 5, size: 10, color: fg, bold: false)
        if !nav.guiding { text(ctx, T("Free drive"), x: 8, y: H - 22, size: 14, color: fg) }
    }

    private func drawLabels(_ ctx: CGContext, _ labels: [PlacedLabel], toScreen: (CGPoint) -> CGPoint?,
                            W: CGFloat, H: CGFloat, dark: Bool, taken: inout [CGRect]) {
        guard !labels.isEmpty else { return }
        let sorted = labels.sorted { $0.priority < $1.priority }
        var drawn = 0
        let fill = dark ? CGColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1) : CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let halo = dark ? CGColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        for l in sorted {
            if drawn >= 6 { break }
            guard let sp = toScreen(l.local) else { continue }
            let sx = sp.x, sy = sp.y
            let size: CGFloat = l.priority <= 1 ? 15 : (l.priority == 2 ? 13 : 11)
            let w = CGFloat(l.name.count) * size * 0.58 + 6
            let rect = CGRect(x: sx - w / 2, y: sy - size / 2, width: w, height: size + 4)
            guard rect.minX > 0, rect.maxX < W, rect.minY > 0, rect.maxY < H else { continue }
            if taken.contains(where: { $0.intersects(rect) }) { continue }
            taken.append(rect)
            text(ctx, l.name, x: rect.minX + 3, y: rect.minY + 2, size: size, color: fill, bold: l.priority <= 2, halo: halo)
            drawn += 1
        }
    }

    /// Název ulice podél silnice: najde nejdelší téměř rovný úsek na obrazovce a text otočí podél něj.
    private func drawRoadLabels(_ ctx: CGContext, _ roads: [PlacedRoad], toScreen: (CGPoint) -> CGPoint?,
                                W: CGFloat, H: CGFloat, dark: Bool, taken: inout [CGRect]) {
        guard !roads.isEmpty else { return }
        let fill = dark ? CGColor(red: 0.86, green: 0.88, blue: 0.91, alpha: 1) : CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)
        let halo = dark ? CGColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        var usedNames = Set<String>()
        var drawn = 0
        for r in roads.sorted(by: { $0.priority < $1.priority }) {
            if drawn >= 5 { break }
            if usedNames.contains(r.name) { continue }
            let size: CGFloat = r.priority <= 1 ? 12 : 11
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let tw = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: r.name, attributes: attrs)), nil, nil, nil))
            let pts = r.local.compactMap { toScreen($0) }
            guard pts.count >= 2 else { continue }
            // nejdelší téměř rovný úsek (tětiva přes body s odchylkou < 20°)
            var best: (CGPoint, CGPoint, CGFloat)? = nil
            for i in 0..<(pts.count - 1) {
                var j = i + 1
                let base = atan2(pts[j].y - pts[i].y, pts[j].x - pts[i].x)
                while j + 1 < pts.count {
                    let a2 = atan2(pts[j + 1].y - pts[j].y, pts[j + 1].x - pts[j].x)
                    var d = abs(a2 - base)
                    if d > .pi { d = 2 * .pi - d }
                    if d > 0.35 { break }
                    j += 1
                }
                let len = hypot(pts[j].x - pts[i].x, pts[j].y - pts[i].y)
                if len > tw + 14 && len > (best?.2 ?? 0) { best = (pts[i], pts[j], len) }
            }
            guard let bst = best else { continue }
            let a = bst.0, b = bst.1
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            guard mid.x > 25, mid.x < W - 25, mid.y > 14, mid.y < H - 14 else { continue }
            var ang = atan2(b.y - a.y, b.x - a.x)
            if ang > .pi / 2 { ang -= .pi } else if ang < -.pi / 2 { ang += .pi }
            let bw = abs(tw * cos(ang)) + abs(size * sin(ang)) + 6
            let bh = abs(tw * sin(ang)) + abs(size * cos(ang)) + 4
            let rect = CGRect(x: mid.x - bw / 2, y: mid.y - bh / 2, width: bw, height: bh)
            if taken.contains(where: { $0.intersects(rect) }) { continue }
            taken.append(rect)
            usedNames.insert(r.name)
            ctx.saveGState()
            ctx.translateBy(x: mid.x, y: mid.y)
            ctx.rotate(by: ang)
            text(ctx, r.name, x: -tw / 2, y: -size * 0.35, size: size, color: fill, bold: true, halo: halo)
            ctx.restoreGState()
            drawn += 1
        }
    }

    /// Šachovnicová vlajka: tyčka zapíchnutá v cíli, praporek 15×10 px.
    private func drawFinishFlag(_ ctx: CGContext, at p: CGPoint) {
        ctx.saveGState()
        let poleTop = CGPoint(x: p.x, y: p.y + 24)
        // tyčka s tmavým obrysem
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.8)); ctx.setLineWidth(4)
        ctx.move(to: p); ctx.addLine(to: poleTop); ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.setLineWidth(2)
        ctx.move(to: p); ctx.addLine(to: poleTop); ctx.strokePath()
        // praporek 3×2 políčka
        let cell: CGFloat = 5
        let origin = CGPoint(x: p.x + 1, y: poleTop.y - 2 * cell)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: origin.x - 1, y: origin.y - 1, width: 3 * cell + 2, height: 2 * cell + 2))
        for i in 0..<3 {
            for j in 0..<2 where (i + j) % 2 == 0 {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: origin.x + CGFloat(i) * cell, y: origin.y + CGFloat(j) * cell, width: cell, height: cell))
            }
        }
        // tečka v místě cíle
        ctx.setFillColor(CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
        ctx.restoreGState()
    }

    /// Vynechá body blíž než ~2 px (celá trasa může mít tisíce bodů).
    private func decimate(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for q in pts.dropFirst() {
            if let l = out.last, abs(q.x - l.x) + abs(q.y - l.y) < 2 { continue }
            out.append(q)
        }
        if let e = pts.last, out.last != e { out.append(e) }
        return out
    }

    private func strokePath(_ ctx: CGContext, _ path: CGPath, color: CGColor, width: CGFloat) {
        guard !path.isEmpty else { return }
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    private func stroke(_ ctx: CGContext, _ pts: [CGPoint], color: CGColor, width: CGFloat) {
        guard pts.count >= 2 else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: pts[0])
        var last = pts[0]
        for q in pts.dropFirst() {
            // body blíž než 1,5 px vynecháme – na displeji nejsou vidět
            if abs(q.x - last.x) + abs(q.y - last.y) < 1.5 { continue }
            ctx.addLine(to: q)
            last = q
        }
        if let end = pts.last, end != last { ctx.addLine(to: end) }
        ctx.strokePath()
    }

    // MARK: Šipka + vzdálenost (přístrojovka ji v režimu mapy sama nekreslí)
    private func drawTurnBox(_ ctx: CGContext, nav: NavSnapshot, H: CGFloat) {
        let box = CGRect(x: 4, y: H - 66, width: 172, height: 62)
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.78))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
        drawTurnGlyph(ctx, icon: nav.icon, center: CGPoint(x: box.minX + 32, y: box.midY), size: 46,
                      rbExit: nav.rbExit, rbAround: nav.rbAround)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let dist: String
        if nav.arrived { dist = T("Destination") } else {
            let (d, u) = formatDistance(nav.toNext)
            dist = u == "m" ? "\(Int(d)) m" : String(format: "%.1f km", d)
        }
        text(ctx, dist, x: box.minX + 64, y: box.midY - 2, size: 24, color: white)
        var road = nav.road
        if road.count > 17 { road = String(road.prefix(16)) + "…" }
        text(ctx, road, x: box.minX + 64, y: box.minY + 8, size: 12, color: CGColor(red: 0.8, green: 0.85, blue: 0.9, alpha: 1), bold: false)
        ctx.restoreGState()
    }

    private func drawTurnGlyph(_ ctx: CGContext, icon: UInt8, center c: CGPoint, size s: CGFloat,
                               rbExit: Int, rbAround: Double) {
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let accent = CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1)
        ctx.setStrokeColor(white)
        ctx.setFillColor(white)
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        func head(at e: CGPoint, dir: CGPoint) {
            let perp = CGPoint(x: dir.y, y: -dir.x)
            ctx.move(to: CGPoint(x: e.x + dir.x * 10, y: e.y + dir.y * 10))
            ctx.addLine(to: CGPoint(x: e.x + perp.x * 9, y: e.y + perp.y * 9))
            ctx.addLine(to: CGPoint(x: e.x - perp.x * 9, y: e.y - perp.y * 9))
            ctx.closePath()
            ctx.fillPath()
        }

        switch icon {
        case 0, 1, 2, 3, 4, 5:        // cíl
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(4)
            ctx.strokeEllipse(in: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28))
            ctx.setFillColor(accent)
            ctx.fillEllipse(in: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
        case 14...31:                  // kruhový objezd: příjezd zdola, míjené výjezdy šedě, náš se šipkou
            let r: CGFloat = 10
            let rc = CGPoint(x: c.x, y: c.y + 3)
            // bod na kruhu podle úhlu objetého od vjezdu (0 = dole, 90 = vpravo, 180 = nahoře, 270 = vlevo)
            func onCircle(_ deg: Double, _ rr: CGFloat) -> CGPoint {
                let a = CGFloat(deg * .pi / 180)
                return CGPoint(x: rc.x + rr * sin(a), y: rc.y - rr * cos(a))
            }
            let target = (icon >= 15 && icon <= 22) ? rbAround : 135
            let exits = max(1, rbExit)
            // míjené výjezdy
            if exits > 1 {
                ctx.setStrokeColor(CGColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1))
                ctx.setLineWidth(4)
                for k in 1..<exits {
                    let deg = target * Double(k) / Double(exits)
                    ctx.move(to: onCircle(deg, r))
                    ctx.addLine(to: onCircle(deg, r + 8))
                }
                ctx.strokePath()
            }
            ctx.setStrokeColor(white)
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: CGRect(x: rc.x - r, y: rc.y - r, width: 2 * r, height: 2 * r))
            ctx.setLineWidth(6)
            ctx.move(to: CGPoint(x: rc.x, y: c.y - s / 2))
            ctx.addLine(to: onCircle(0, r))
            ctx.strokePath()
            // náš výjezd se šipkou
            let st = onCircle(target, r)
            let e = onCircle(target, r + 9)
            let dirLen = hypot(e.x - st.x, e.y - st.y)
            let d = CGPoint(x: (e.x - st.x) / dirLen, y: (e.y - st.y) / dirLen)
            ctx.move(to: st); ctx.addLine(to: e); ctx.strokePath()
            head(at: e, dir: d)
        case 36, 37:                   // otočka
            let m: CGFloat = icon == 36 ? 1 : -1
            let x1 = c.x + m * 9, x2 = c.x - m * 9
            ctx.move(to: CGPoint(x: x1, y: c.y - s / 2))
            ctx.addLine(to: CGPoint(x: x1, y: c.y + 6))
            ctx.addArc(center: CGPoint(x: c.x, y: c.y + 6), radius: 9, startAngle: m > 0 ? 0 : .pi, endAngle: m > 0 ? .pi : 0, clockwise: m < 0)
            ctx.addLine(to: CGPoint(x: x2, y: c.y - 6))
            ctx.strokePath()
            head(at: CGPoint(x: x2, y: c.y - 8), dir: CGPoint(x: 0, y: -1))
        default:
            let deg: CGFloat
            switch icon {
            case 8, 9: deg = 0
            case 6, 10: deg = -45
            case 7, 11: deg = 45
            case 34: deg = -90
            case 35: deg = 90
            case 32: deg = -135
            case 33: deg = 135
            default: deg = 0
            }
            let a = deg * .pi / 180
            let d = CGPoint(x: sin(a), y: cos(a))
            let pivot = CGPoint(x: c.x, y: c.y - 2)
            let e = CGPoint(x: pivot.x + d.x * 13, y: pivot.y + d.y * 13)
            ctx.move(to: CGPoint(x: c.x, y: c.y - s / 2))
            ctx.addLine(to: pivot)
            ctx.addLine(to: e)
            ctx.strokePath()
            head(at: e, dir: d)
        }
    }

    // MARK: Testovací obraz (simulace / bez polohy)
    private func drawTestPattern(_ ctx: CGContext, frame n: Int, nav: NavSnapshot?, p: RenderParams) {
        let W = CGFloat(p.width), H = CGFloat(p.height)
        ctx.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.21, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setStrokeColor(CGColor(red: 0.32, green: 0.35, blue: 0.40, alpha: 1))
        ctx.setLineWidth(5)
        let off = CGFloat((n * 7) % 60)
        var y = -60 + off
        while y < H + 60 { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); y += 60 }
        var x: CGFloat = 20
        while x < W { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)); x += 80 }
        ctx.strokePath()
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let yellow = CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1)
        text(ctx, "TEST #\(n)", x: W - 150, y: H - 56, size: 18, color: yellow)
        text(ctx, timeFmt.string(from: Date()), x: W - 100, y: H - 28, size: 18, color: white)
        if nav == nil { text(ctx, T("Waiting for location…"), x: 190, y: 20, size: 16, color: white) }
    }

    private func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor,
                      bold: Bool = true, halo: CGColor? = nil) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        ctx.textMatrix = .identity
        if let h = halo {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): h,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): h,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): 22.0,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
}

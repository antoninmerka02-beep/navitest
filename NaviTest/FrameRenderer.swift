import Foundation
import CoreGraphics
import CoreText
import ImageIO
import MapKit

enum MapSource: String, CaseIterable, Identifiable {
    case vector, own, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vector: return "Mapa OSM"
        case .own: return "Jen trasa"
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

        var labels: [PlacedLabel] = []
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
            labels = vector.draw(ctx, pos: pos, mpp: p.mpp, radiusPx: radius, dark: p.dark)
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

        // Popisky obcí – svisle, bez překryvů
        drawLabels(ctx, labels, anchor: anchor, theta: theta, W: W, H: H, dark: p.dark)

        // šipka polohy
        ctx.saveGState()
        ctx.translateBy(x: anchor.x, y: anchor.y)
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
        if !nav.guiding { text(ctx, "Volná jízda", x: 8, y: H - 22, size: 14, color: fg) }
    }

    private func drawLabels(_ ctx: CGContext, _ labels: [PlacedLabel], anchor: CGPoint, theta: CGFloat, W: CGFloat, H: CGFloat, dark: Bool) {
        guard !labels.isEmpty else { return }
        let c = cos(theta), s = sin(theta)
        var taken: [CGRect] = [
            CGRect(x: 0, y: H - 72, width: 180, height: 72),        // box se šipkou
            CGRect(x: anchor.x - 30, y: anchor.y - 30, width: 60, height: 60),   // naše poloha
            CGRect(x: W - 70, y: 0, width: 70, height: 70),         // limit přístrojovky
            CGRect(x: 0, y: 40, width: 60, height: 120),            // tlačítka +/− přístrojovky
        ]
        let sorted = labels.sorted { $0.priority < $1.priority }
        var drawn = 0
        let fill = dark ? CGColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1) : CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let halo = dark ? CGColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        for l in sorted {
            if drawn >= 6 { break }
            let sx = anchor.x + l.local.x * c - l.local.y * s
            let sy = anchor.y + l.local.x * s + l.local.y * c
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

    private func stroke(_ ctx: CGContext, _ pts: [CGPoint], color: CGColor, width: CGFloat) {
        guard pts.count >= 2 else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: pts[0])
        for q in pts.dropFirst() { ctx.addLine(to: q) }
        ctx.strokePath()
    }

    // MARK: Šipka + vzdálenost (přístrojovka ji v režimu mapy sama nekreslí)
    private func drawTurnBox(_ ctx: CGContext, nav: NavSnapshot, H: CGFloat) {
        let box = CGRect(x: 4, y: H - 66, width: 172, height: 62)
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.78))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
        drawTurnGlyph(ctx, icon: nav.icon, center: CGPoint(x: box.minX + 32, y: box.midY), size: 46)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let dist: String
        if nav.arrived { dist = "Cíl" } else {
            let (d, u) = formatDistance(nav.toNext)
            dist = u == "m" ? "\(Int(d)) m" : String(format: "%.1f km", d)
        }
        text(ctx, dist, x: box.minX + 64, y: box.midY - 2, size: 24, color: white)
        var road = nav.road
        if road.count > 17 { road = String(road.prefix(16)) + "…" }
        text(ctx, road, x: box.minX + 64, y: box.minY + 8, size: 12, color: CGColor(red: 0.8, green: 0.85, blue: 0.9, alpha: 1), bold: false)
        ctx.restoreGState()
    }

    private func drawTurnGlyph(_ ctx: CGContext, icon: UInt8, center c: CGPoint, size s: CGFloat) {
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
        case 13...31:                  // kruhový objezd
            let rc = CGPoint(x: c.x, y: c.y + 2)
            ctx.strokeEllipse(in: CGRect(x: rc.x - 10, y: rc.y - 10, width: 20, height: 20))
            ctx.move(to: CGPoint(x: rc.x, y: c.y - s / 2))
            ctx.addLine(to: CGPoint(x: rc.x, y: rc.y - 10))
            ctx.strokePath()
            let d = CGPoint(x: 0.707, y: 0.707)
            let st = CGPoint(x: rc.x + 7, y: rc.y + 7)
            let e = CGPoint(x: st.x + d.x * 8, y: st.y + d.y * 8)
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
        if nav == nil { text(ctx, "Čekám na polohu…", x: 190, y: 20, size: 16, color: white) }
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

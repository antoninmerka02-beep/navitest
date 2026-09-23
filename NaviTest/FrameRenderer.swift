import Foundation
import CoreGraphics
import CoreText
import ImageIO
import MapKit

struct RenderParams {
    var width = 480
    var height = 240
    var quality = 0.5
    var mpp = 3.0            // metrů na pixel (zoom)
    var northUp = false
    var dark = true
    var note = ""
}

/// Kreslí snímek čistě na CPU (Core Graphics) – funguje i se zamčeným telefonem.
final class FrameRenderer {
    private let cs = CGColorSpaceCreateDeviceRGB()
    private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func render(frame n: Int, nav: NavSnapshot?, p: RenderParams, snap: MapSnapshotProvider.Snap?) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: p.width, height: p.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        if let nav = nav, let pos = nav.position {
            drawMap(ctx, nav: nav, pos: pos, p: p, snap: snap, frame: n)
        } else {
            drawTestPattern(ctx, frame: n, nav: nav, p: p)
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
        let bg = p.dark ? CGColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1) : CGColor(red: 0.93, green: 0.92, blue: 0.89, alpha: 1)
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        let anchor = CGPoint(x: W / 2, y: 62)
        let theta = p.northUp ? 0 : CGFloat(nav.heading * .pi / 180)

        // Převod souřadnic do lokálních pixelů (sever nahoru, y nahoru, poloha = 0,0)
        let local: (CLLocationCoordinate2D) -> CGPoint
        if let s = snap {
            let p0 = s.snapshot.point(for: pos)
            local = { c in
                let q = s.snapshot.point(for: c)
                return CGPoint(x: q.x - p0.x, y: p0.y - q.y)
            }
        } else {
            let a = MKMapPoint(pos)
            let k = MKMetersPerMapPointAtLatitude(pos.latitude) / p.mpp
            local = { c in
                let b = MKMapPoint(c)
                return CGPoint(x: (b.x - a.x) * k, y: -(b.y - a.y) * k)
            }
        }

        ctx.saveGState()
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.rotate(by: theta)
        if let s = snap {
            let p0 = s.snapshot.point(for: pos)
            let sw = CGFloat(s.image.width), sh = CGFloat(s.image.height)
            ctx.draw(s.image, in: CGRect(x: -p0.x, y: p0.y - sh, width: sw, height: sh))
        }
        // ujetá část trasy
        stroke(ctx, nav.routeBehind.map(local), color: CGColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 0.9), width: 9)
        // trasa před námi: tmavý okraj + tyrkysová
        let ahead = nav.routeAhead.map(local)
        stroke(ctx, ahead, color: CGColor(red: 0.0, green: 0.25, blue: 0.3, alpha: 1), width: 14)
        stroke(ctx, ahead, color: CGColor(red: 0.0, green: 0.85, blue: 0.95, alpha: 1), width: 9)
        // místo manévru
        if let mp = nav.maneuverPoint, nav.guiding {
            let q = local(mp)
            ctx.setFillColor(CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: q.x - 7, y: q.y - 7, width: 14, height: 14))
        }
        ctx.restoreGState()

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

        // malý ladicí text
        let fg = p.dark ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.85) : CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
        text(ctx, "#\(n) \(timeFmt.string(from: Date())) · \(snap != nil ? "Apple" : "vlastní") · \(p.note)", x: 6, y: 6, size: 11, color: fg, bold: false)
        if !nav.guiding { text(ctx, "Volná jízda – žádná trasa", x: 6, y: H - 20, size: 14, color: fg) }
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
        // červený okraj obrázku – ať je vidět, kolik z něj přístrojovka ukazuje
        ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
        ctx.setLineWidth(4)
        ctx.stroke(CGRect(x: 2, y: 2, width: W - 4, height: H - 4))

        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let yellow = CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1)
        text(ctx, "TEST #\(n)", x: 10, y: H - 28, size: 20, color: yellow)
        text(ctx, timeFmt.string(from: Date()), x: W - 100, y: H - 28, size: 20, color: white)
        if let nav = nav {
            let (d, u) = formatDistance(nav.toNext)
            let dStr = u == "m" ? "\(Int(d)) m" : String(format: "%.1f km", d)
            text(ctx, "\(dStr) · \(TurnIcon.name(nav.icon)) (\(nav.icon))", x: 10, y: H - 54, size: 17, color: white)
        } else {
            text(ctx, "Čekám na polohu…", x: 10, y: H - 54, size: 17, color: white)
        }
        text(ctx, "šířka \(p.width) px · \(p.note)", x: 10, y: 10, size: 13, color: white, bold: false)
    }

    private func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor, bold: Bool = true) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
}

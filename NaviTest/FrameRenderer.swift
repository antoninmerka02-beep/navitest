import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// Kreslí testovací snímek 480×240 čistě na CPU (Core Graphics), takže funguje i se zamčeným
/// telefonem na pozadí – iOS na pozadí nepovolí GPU (Metal/MapKit).
final class FrameRenderer {
    let width = 480
    let height = 240
    private let cs = CGColorSpaceCreateDeviceRGB()
    private let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    func render(frame n: Int, sim: SimSnapshot, quality: Double, note: String) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let W = CGFloat(width), H = CGFloat(height)

        // Podklad „mapy“
        ctx.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.21, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // Pohybující se mřížka ulic (ať je vidět, že obraz žije)
        ctx.setStrokeColor(CGColor(red: 0.32, green: 0.35, blue: 0.40, alpha: 1))
        ctx.setLineWidth(5)
        let off = CGFloat((n * 7) % 60)
        var y = -60 + off
        while y < H + 60 { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); y += 60 }
        var x: CGFloat = 20
        while x < W { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)); x += 80 }
        ctx.strokePath()

        // Trasa (tyrkysová) podle typu manévru
        let cx = W / 2, turnY = 60 + CGFloat(min(sim.toNext, 600) / 600) * 120
        ctx.setStrokeColor(CGColor(red: 0.0, green: 0.85, blue: 0.95, alpha: 1))
        ctx.setLineWidth(12)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: cx, y: 30))
        ctx.addLine(to: CGPoint(x: cx, y: turnY))
        switch sim.maneuver.icon {
        case 34, 32, 3, 10: ctx.addLine(to: CGPoint(x: cx - 150, y: turnY))          // vlevo
        case 35, 33, 11: ctx.addLine(to: CGPoint(x: cx + 150, y: turnY))              // vpravo
        case 6: ctx.addLine(to: CGPoint(x: cx - 60, y: H))                            // držet vlevo
        case 7: ctx.addLine(to: CGPoint(x: cx + 60, y: H))                            // držet vpravo
        default: ctx.addLine(to: CGPoint(x: cx, y: H))                                // rovně / ostatní
        }
        ctx.strokePath()

        // Poloha (šipka)
        ctx.setFillColor(CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1))
        ctx.move(to: CGPoint(x: cx, y: 52))
        ctx.addLine(to: CGPoint(x: cx - 13, y: 18))
        ctx.addLine(to: CGPoint(x: cx, y: 26))
        ctx.addLine(to: CGPoint(x: cx + 13, y: 18))
        ctx.closePath(); ctx.fillPath()

        // Texty (Core Text kreslí v souřadnicích s počátkem vlevo dole)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let yellow = CGColor(red: 0.85, green: 1.0, blue: 0.0, alpha: 1)
        text(ctx, "TEST #\(n)", x: 10, y: H - 28, size: 20, color: yellow)
        text(ctx, timeFmt.string(from: Date()), x: W - 100, y: H - 28, size: 20, color: white)
        let (d, u) = formatDistance(sim.toNext)
        let dStr = u == "m" ? "\(Int(d)) m" : String(format: "%.1f km", d)
        text(ctx, "\(dStr) · ikona \(sim.maneuver.icon)", x: 10, y: H - 54, size: 17, color: white)
        text(ctx, note, x: 10, y: 8, size: 13, color: white, bold: false)

        guard let img = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](data as Data)
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

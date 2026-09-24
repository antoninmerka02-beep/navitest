import Foundation
import CoreGraphics

/// 3D pohled: kamera za motorkou nad terénem, nakloněná dolů. Vstup jsou lokální pixely
/// (sever nahoru, y nahoru, poloha = 0,0 – stejné jako ve 2D), výstup souřadnice obrázku (y nahoru).
/// Měřítko u polohy odpovídá 2D (1 px = 1 px), dál se mapa zmenšuje a vidíš ~5× dál dopředu.
struct Perspective {
    let W: CGFloat, H: CGFloat
    let F: CGFloat = 300                 // ohnisková vzdálenost v px
    let cx: CGFloat, cy: CGFloat
    let sinA: CGFloat, cosA: CGFloat     // náklon kamery pod vodorovnou rovinu
    let b: CGFloat, h: CGFloat           // kamera je b px za polohou a h px nad terénem
    let ct: CGFloat, st: CGFloat         // otočení podle kurzu (po směru jízdy nahoru)
    let near: CGFloat = 15

    init(W: CGFloat, H: CGFloat, anchorY: CGFloat, headingRad: CGFloat, pitchDeg: CGFloat = 33) {
        self.W = W; self.H = H
        cx = W / 2; cy = H / 2
        let a = pitchDeg * .pi / 180
        sinA = sin(a); cosA = cos(a)
        let z0 = F, y0 = anchorY - cy       // poloha se promítne na (W/2, anchorY) s měřítkem 1
        b = z0 * cosA + y0 * sinA
        h = z0 * sinA - y0 * cosA
        ct = cos(headingRad); st = sin(headingRad)
    }

    /// Lokální pixely → souřadnice kamery (X doprava, Y nahoru, Z do hloubky).
    @inline(__always) func cam(_ p: CGPoint) -> (x: CGFloat, y: CGFloat, z: CGFloat) {
        let hx = p.x * ct - p.y * st
        let hy = p.x * st + p.y * ct
        return (hx, (hy + b) * sinA - h * cosA, (hy + b) * cosA + h * sinA)
    }

    @inline(__always) func screen(_ c: (x: CGFloat, y: CGFloat, z: CGFloat)) -> CGPoint {
        CGPoint(x: cx + F * c.x / c.z, y: cy + F * c.y / c.z)
    }

    /// Promítne bod; nil, když je za kamerou.
    func project(_ p: CGPoint) -> CGPoint? {
        let c = cam(p)
        return c.z > near ? screen(c) : nil
    }

    /// Bod obrázku → místo na zemi (lokální pixely). Pro výběr dlaždic.
    func ground(_ sx: CGFloat, _ sy: CGFloat) -> CGPoint? {
        let a = (sx - cx) / F, c = (sy - cy) / F
        let den = sinA - c * cosA
        guard den > 0.02 else { return nil }
        let t = h / den
        let gx = a * t, gy = -b + t * (c * sinA + cosA)
        return CGPoint(x: gx * ct + gy * st, y: -gx * st + gy * ct)
    }

    /// Obdélník na zemi, který pokrývá celý obrázek (lokální pixely).
    func groundBounds(margin: CGFloat = 40) -> CGRect {
        var pts: [CGPoint] = []
        for sx in [0, W / 2, W] {
            for sy in [0, H] {
                if let g = ground(sx, sy) { pts.append(g) }
            }
        }
        pts.append(.zero)
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return r.insetBy(dx: -margin, dy: -margin)
    }

    /// Přidá čáru nebo plochu do cesty s ořezem u kamery (Z > near).
    func add(_ pts: [CGPoint], closed: Bool, to path: CGMutablePath) {
        guard pts.count >= 2 else { return }
        let c = pts.map { cam($0) }
        if closed {
            // Sutherland–Hodgman proti rovině Z = near
            var out: [(x: CGFloat, y: CGFloat, z: CGFloat)] = []
            out.reserveCapacity(c.count + 4)
            for i in 0..<c.count {
                let cur = c[i], prev = c[(i + c.count - 1) % c.count]
                let curIn = cur.z > near, prevIn = prev.z > near
                if curIn {
                    if !prevIn { out.append(cut(prev, cur)) }
                    out.append(cur)
                } else if prevIn {
                    out.append(cut(prev, cur))
                }
            }
            guard out.count >= 3 else { return }
            path.move(to: screen(out[0]))
            for q in out.dropFirst() { path.addLine(to: screen(q)) }
            path.closeSubpath()
        } else {
            var drawing = false
            for i in 0..<c.count {
                let cur = c[i]
                if i == 0 {
                    if cur.z > near { path.move(to: screen(cur)); drawing = true }
                    continue
                }
                let prev = c[i - 1]
                let curIn = cur.z > near, prevIn = prev.z > near
                if curIn && prevIn {
                    path.addLine(to: screen(cur))
                } else if curIn && !prevIn {
                    path.move(to: screen(cut(prev, cur)))
                    path.addLine(to: screen(cur))
                    drawing = true
                } else if !curIn && prevIn {
                    path.addLine(to: screen(cut(prev, cur)))
                    drawing = false
                }
            }
            _ = drawing
        }
    }

    @inline(__always) private func cut(_ a: (x: CGFloat, y: CGFloat, z: CGFloat), _ b: (x: CGFloat, y: CGFloat, z: CGFloat))
        -> (x: CGFloat, y: CGFloat, z: CGFloat) {
        let t = (near - a.z) / (b.z - a.z)
        return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, near)
    }

    /// Převede cestu z dlaždice (souřadnice dlaždice) přes afinní transformaci do perspektivy.
    func add(tilePath: CGPath, transform t: CGAffineTransform, closed: Bool, to out: CGMutablePath) {
        var ring: [CGPoint] = []
        ring.reserveCapacity(64)
        func flush(_ close: Bool) {
            if ring.count >= 2 { add(ring, closed: close, to: out) }
            ring.removeAll(keepingCapacity: true)
        }
        tilePath.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                flush(closed)
                ring.append(e.points[0].applying(t))
            case .addLineToPoint:
                ring.append(e.points[0].applying(t))
            case .closeSubpath:
                flush(true)
            default:
                break
            }
        }
        flush(closed)
    }
}

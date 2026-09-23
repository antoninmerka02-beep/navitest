import Foundation
import CoreGraphics
import MapKit

private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Barvy a tloušťky – tmavý styl ladící s přístrojovkou R9 (a světlá varianta).
enum VStyle {
    static func background(dark: Bool) -> CGColor { dark ? rgb(0x1B1E23) : rgb(0xEEEBE5) }

    static func fill(_ b: VBucket, dark: Bool) -> CGColor {
        switch b {
        case .residential: return dark ? rgb(0x262A31) : rgb(0xE2DFD9)
        case .grass: return dark ? rgb(0x1F2922) : rgb(0xDCE8D2)
        case .wood: return dark ? rgb(0x1B2A20) : rgb(0xC9DDBE)
        case .water: return dark ? rgb(0x1C3A5A) : rgb(0xA9CBEA)
        default: return rgb(0x000000)
        }
    }

    /// (barva, tloušťka v px při ~3 m/px)
    static func line(_ b: VBucket, dark: Bool) -> (CGColor, CGFloat) {
        switch b {
        case .waterway: return (dark ? rgb(0x2B5680) : rgb(0x8DB8E2), 1.5)
        case .rail: return (dark ? rgb(0x4A4F57) : rgb(0xA8A8A8), 1.0)
        case .track: return (dark ? rgb(0x3A3F47) : rgb(0xC8BFAF), 1.0)
        case .service: return (dark ? rgb(0x4E545D) : rgb(0xFFFFFF), 1.3)
        case .minor: return (dark ? rgb(0x6A717B) : rgb(0xFFFFFF), 2.3)
        case .tertiary: return (dark ? rgb(0x8D949E) : rgb(0xFFFFFF), 3.0)
        case .secondary: return (dark ? rgb(0xB8BDC5) : rgb(0xF7E9A6), 3.6)
        case .primary: return (dark ? rgb(0xE0C665) : rgb(0xF2CF6B), 4.2)
        case .trunk: return (dark ? rgb(0xE89E4A) : rgb(0xEFA35A), 4.8)
        case .motorway: return (dark ? rgb(0xE8773E) : rgb(0xE8773E), 5.2)
        default: return (rgb(0x888888), 1)
        }
    }
}

struct PlacedLabel {
    let local: CGPoint      // lokální pixely (sever nahoru, y nahoru, poloha = 0,0)
    let name: String
    let priority: Int
}

/// Kreslí vektorovou mapu do kontextu, který je už posunutý na polohu a otočený podle kurzu.
final class VectorMapRenderer {
    private let store = TileStore.shared
    private let world = MKMapSize.world.width

    /// Vybere zoom dlaždic podle měřítka (dlaždice na displeji ~256–512 px), max 14 (pak se zvětšuje).
    func tileZoom(pxPerMapPoint k: Double) -> Int {
        let z = Int(floor(log2(k * world / 256)))
        return min(store.maxZoom, max(5, z))
    }

    /// Vrací popisky k vykreslení až po otočení kontextu zpět (aby byly svisle).
    func draw(_ ctx: CGContext, pos: CLLocationCoordinate2D, mpp: Double, radiusPx: CGFloat, dark: Bool) -> [PlacedLabel] {
        let posMP = MKMapPoint(pos)
        let k = MKMetersPerMapPointAtLatitude(pos.latitude) / mpp      // px na map point
        let z = tileZoom(pxPerMapPoint: k)
        let n = 1 << z
        let s = world / Double(n)
        let r = Double(radiusPx) / k
        let x0 = max(0, Int(floor((posMP.x - r) / s))), x1 = min(n - 1, Int(floor((posMP.x + r) / s)))
        let y0 = max(0, Int(floor((posMP.y - r) / s))), y1 = min(n - 1, Int(floor((posMP.y + r) / s)))
        guard x0 <= x1, y0 <= y1 else { return [] }

        // Vybrat dlaždice k vykreslení; chybějící nahradit načteným „rodičem“ z nižšího zoomu.
        var draw: [VTile] = []
        var used = Set<TileKey>()
        for x in x0...x1 {
            for y in y0...y1 {
                let key = TileKey(z: z, x: x, y: y)
                if let t = store.tile(key) {
                    if used.insert(key).inserted { draw.append(t) }
                    continue
                }
                store.request(key)
                var d = 1
                while d <= 4 && z - d >= 0 {
                    let pk = TileKey(z: z - d, x: x >> d, y: y >> d)
                    if let pt = store.tile(pk) {
                        if used.insert(pk).inserted { draw.append(pt) }
                        break
                    }
                    d += 1
                }
            }
        }
        draw.sort { $0.key.z < $1.key.z }

        func transform(_ t: VTile) -> CGAffineTransform {
            let ts = world / Double(1 << t.key.z)
            let a = k * ts / Double(t.extent)
            return CGAffineTransform(a: CGFloat(a), b: 0, c: 0, d: CGFloat(-a),
                                     tx: CGFloat(k * (Double(t.key.x) * ts - posMP.x)),
                                     ty: CGFloat(-k * (Double(t.key.y) * ts - posMP.y)))
        }
        let transforms = draw.map { transform($0) }

        // Tloušťky čar mírně podle měřítka
        let f = CGFloat(min(1.7, max(0.55, pow(3.0 / mpp, 0.3))))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for b in VBucket.allCases {
            var any = false
            for (i, t) in draw.enumerated() {
                guard let p = t.paths[b] else { continue }
                var tr = transforms[i]
                if let tp = p.copy(using: &tr) { ctx.addPath(tp); any = true }
            }
            guard any else { continue }
            if b.isFill {
                ctx.setFillColor(VStyle.fill(b, dark: dark))
                ctx.fillPath()
            } else {
                let (c, w) = VStyle.line(b, dark: dark)
                ctx.setStrokeColor(c)
                ctx.setLineWidth(w * f)
                ctx.strokePath()
            }
        }

        // Popisky obcí (filtr podle zoomu)
        let maxPrio = z >= 13 ? 3 : (z >= 11 ? 2 : 1)
        var labels: [PlacedLabel] = []
        for (i, t) in draw.enumerated() {
            for l in t.labels where l.priority <= maxPrio {
                let p = l.point.applying(transforms[i])
                labels.append(PlacedLabel(local: p, name: l.name, priority: l.priority))
            }
        }
        return labels
    }
}

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

struct PlacedRoad {
    let local: [CGPoint]    // lokální pixely
    let name: String
    let priority: Int
}

struct VMapResult {
    var places: [PlacedLabel] = []
    var roads: [PlacedRoad] = []
}

/// Kreslí vektorovou mapu – 2D (kontext posunutý na polohu a otočený podle kurzu) nebo 3D (perspektiva).
final class VectorMapRenderer {
    private let store = TileStore.shared
    private let world = MKMapSize.world.width

    /// Zoom dlaždic podle měřítka (dlaždice na displeji ~256–512 px), max 14 (pak se zvětšuje).
    func tileZoom(pxPerMapPoint k: Double) -> Int {
        let z = Int(floor(log2(k * world / 256)))
        return min(store.maxZoom, max(5, z))
    }

    /// Vybere dlaždice pokrývající obdélník v lokálních pixelech; chybějící nahradí rodičem z nižšího zoomu.
    private func tiles(pos: CLLocationCoordinate2D, mpp: Double, bounds: CGRect, zoomBias: Int, maxTiles: Int)
        -> (tiles: [VTile], k: Double, posMP: MKMapPoint, z: Int) {
        let posMP = MKMapPoint(pos)
        let k = MKMetersPerMapPointAtLatitude(pos.latitude) / mpp
        var z = max(5, tileZoom(pxPerMapPoint: k) + zoomBias)
        var x0 = 0, x1 = -1, y0 = 0, y1 = -1
        while true {
            let n = 1 << z
            let s = world / Double(n)
            // lokální y je nahoru, map pointy mají y dolů
            let minX = posMP.x + Double(bounds.minX) / k, maxX = posMP.x + Double(bounds.maxX) / k
            let minY = posMP.y - Double(bounds.maxY) / k, maxY = posMP.y - Double(bounds.minY) / k
            x0 = max(0, Int(floor(minX / s))); x1 = min(n - 1, Int(floor(maxX / s)))
            y0 = max(0, Int(floor(minY / s))); y1 = min(n - 1, Int(floor(maxY / s)))
            if (x1 - x0 + 1) * (y1 - y0 + 1) <= maxTiles || z <= 5 { break }
            z -= 1
        }
        guard x0 <= x1, y0 <= y1 else { return ([], k, posMP, z) }
        var out: [VTile] = []
        var used = Set<TileKey>()
        for x in x0...x1 {
            for y in y0...y1 {
                let key = TileKey(z: z, x: x, y: y)
                if let t = store.tile(key) {
                    if used.insert(key).inserted { out.append(t) }
                    continue
                }
                store.request(key)
                var d = 1
                while d <= 4 && z - d >= 0 {
                    let pk = TileKey(z: z - d, x: x >> d, y: y >> d)
                    if let pt = store.tile(pk) {
                        if used.insert(pk).inserted { out.append(pt) }
                        break
                    }
                    d += 1
                }
            }
        }
        out.sort { $0.key.z < $1.key.z }
        return (out, k, posMP, z)
    }

    private func transform(_ t: VTile, k: Double, posMP: MKMapPoint) -> CGAffineTransform {
        let ts = world / Double(1 << t.key.z)
        let a = k * ts / Double(t.extent)
        return CGAffineTransform(a: CGFloat(a), b: 0, c: 0, d: CGFloat(-a),
                                 tx: CGFloat(k * (Double(t.key.x) * ts - posMP.x)),
                                 ty: CGFloat(-k * (Double(t.key.y) * ts - posMP.y)))
    }

    private func lineWidth(_ b: VBucket, mpp: Double, dark: Bool) -> (CGColor, CGFloat) {
        let f = CGFloat(min(1.7, max(0.55, pow(3.0 / mpp, 0.3))))
        let (c, w) = VStyle.line(b, dark: dark)
        return (c, w * f)
    }

    private func labels(_ tiles: [VTile], transforms: [CGAffineTransform], z: Int, mpp: Double, streetNames: Bool) -> VMapResult {
        var res = VMapResult()
        let maxPrio = z >= 13 ? 3 : (z >= 11 ? 2 : 1)
        // názvy ulic jen při přiblížení (místní ulice až úplně zblízka)
        let maxRoadPrio = mpp <= 1.3 ? 5 : (mpp <= 3 ? 4 : (mpp <= 6.5 ? 2 : -1))
        for (i, t) in tiles.enumerated() {
            let tr = transforms[i]
            for l in t.labels where l.priority <= maxPrio {
                res.places.append(PlacedLabel(local: l.point.applying(tr), name: l.name, priority: l.priority))
            }
            if streetNames && maxRoadPrio >= 0 {
                for r in t.roads where r.priority <= maxRoadPrio {
                    res.roads.append(PlacedRoad(local: r.points.map { $0.applying(tr) }, name: r.name, priority: r.priority))
                }
            }
        }
        return res
    }

    /// 2D: kontext je posunutý na polohu a otočený podle kurzu.
    func draw(_ ctx: CGContext, pos: CLLocationCoordinate2D, mpp: Double, radiusPx: CGFloat, dark: Bool, streetNames: Bool) -> VMapResult {
        let bounds = CGRect(x: -radiusPx, y: -radiusPx, width: 2 * radiusPx, height: 2 * radiusPx)
        let (tiles, k, posMP, z) = self.tiles(pos: pos, mpp: mpp, bounds: bounds, zoomBias: 0, maxTiles: 25)
        let transforms = tiles.map { transform($0, k: k, posMP: posMP) }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for b in VBucket.allCases {
            var any = false
            for (i, t) in tiles.enumerated() {
                guard let p = t.paths[b] else { continue }
                var tr = transforms[i]
                if let tp = p.copy(using: &tr) { ctx.addPath(tp); any = true }
            }
            guard any else { continue }
            if b.isFill {
                ctx.setFillColor(VStyle.fill(b, dark: dark))
                ctx.fillPath()
            } else {
                let (c, w) = lineWidth(b, mpp: mpp, dark: dark)
                ctx.setStrokeColor(c)
                ctx.setLineWidth(w)
                ctx.strokePath()
            }
        }
        return labels(tiles, transforms: transforms, z: z, mpp: mpp, streetNames: streetNames)
    }

    /// 3D: kreslí přímo v souřadnicích obrázku přes perspektivu.
    func draw3D(_ ctx: CGContext, pos: CLLocationCoordinate2D, mpp: Double, persp: Perspective, dark: Bool, streetNames: Bool) -> VMapResult {
        let bounds = persp.groundBounds()
        let (tiles, k, posMP, z) = self.tiles(pos: pos, mpp: mpp, bounds: bounds, zoomBias: -1, maxTiles: 30)
        let transforms = tiles.map { transform($0, k: k, posMP: posMP) }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for b in VBucket.allCases {
            let path = CGMutablePath()
            for (i, t) in tiles.enumerated() {
                guard let p = t.paths[b] else { continue }
                persp.add(tilePath: p, transform: transforms[i], closed: b.isFill, to: path)
            }
            guard !path.isEmpty else { continue }
            ctx.addPath(path)
            if b.isFill {
                ctx.setFillColor(VStyle.fill(b, dark: dark))
                ctx.fillPath()
            } else {
                let (c, w) = lineWidth(b, mpp: mpp, dark: dark)
                ctx.setStrokeColor(c)
                ctx.setLineWidth(w)
                ctx.strokePath()
            }
        }
        return labels(tiles, transforms: transforms, z: z, mpp: mpp, streetNames: streetNames)
    }
}

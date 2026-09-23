import Foundation
import MapKit
import UIKit

/// Stahuje severně orientované čtverce Apple mapy (1024×1024 px) kolem polohy.
/// Renderer z posledního čtverce vyřezává a otáčí výřez 480×240 – nový se žádá, až poloha
/// ujede od středu nebo se změní zoom. Loguje, jestli to funguje i na pozadí.
final class MapSnapshotProvider {
    struct Snap {
        let image: CGImage
        let snapshot: MKMapSnapshotter.Snapshot
        let center: CLLocationCoordinate2D
        let mpp: Double
        let dark: Bool
    }

    let size = 1024
    private let lock = NSLock()
    private var current: Snap?
    private var inFlight = false
    private var inFlightSince = Date.distantPast
    private var snapper: MKMapSnapshotter?
    private var _ok = 0, _fail = 0, _okBackground = 0
    private var _lastError = ""

    var stats: String {
        lock.lock(); defer { lock.unlock() }
        return "OK \(_ok) (z toho na pozadí \(_okBackground)) · chyby \(_fail)" + (_lastError.isEmpty ? "" : " · \(_lastError)")
    }

    func latest() -> Snap? { lock.lock(); defer { lock.unlock() }; return current }

    /// Volat z vykreslovacího vlákna. Když je potřeba, spustí stažení nového čtverce.
    func ensure(center: CLLocationCoordinate2D, mpp: Double, dark: Bool) {
        lock.lock()
        var need = false
        if inFlight {
            if Date().timeIntervalSince(inFlightSince) > 20 { inFlight = false; _lastError = "timeout 20 s" }
        }
        if !inFlight {
            if let c = current {
                let moved = MKMapPoint(c.center).distance(to: MKMapPoint(center))
                need = moved > Double(size) * c.mpp * 0.2 || abs(c.mpp - mpp) / mpp > 0.05 || c.dark != dark
            } else {
                need = true
            }
        }
        if need { inFlight = true; inFlightSince = Date() }
        lock.unlock()
        guard need else { return }
        DispatchQueue.main.async { self.start(center: center, mpp: mpp, dark: dark) }
    }

    private func start(center: CLLocationCoordinate2D, mpp: Double, dark: Bool) {
        let o = MKMapSnapshotter.Options()
        let meters = Double(size) * mpp
        o.region = MKCoordinateRegion(center: center, latitudinalMeters: meters, longitudinalMeters: meters)
        o.size = CGSize(width: size, height: size)
        o.scale = 1
        o.mapType = .mutedStandard
        o.pointOfInterestFilter = .excludingAll
        o.showsBuildings = false
        // Vynutit měřítko 1 (iOS jinak vrátí obrázek v rozlišení displeje, např. 3×)
        o.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(displayScale: 1),
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
        ])

        let state = UIApplication.shared.applicationState
        let stateName = state == .background ? "pozadí" : (state == .active ? "popředí" : "neaktivní")
        let started = Date()
        let s = MKMapSnapshotter(options: o)
        snapper = s
        s.start(with: DispatchQueue.global(qos: .userInitiated)) { [weak self] snap, err in
            guard let self = self else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            self.lock.lock()
            if let snap = snap, let cg = snap.image.cgImage {
                self.current = Snap(image: cg, snapshot: snap, center: center, mpp: mpp, dark: dark)
                self._ok += 1
                if state == .background { self._okBackground += 1 }
                let n = self._ok, nb = self._okBackground
                self.lock.unlock()
                if n == 1 || (state == .background && nb <= 3) || n % 20 == 0 {
                    log("🗺️ Apple mapa OK (\(stateName), \(ms) ms, celkem \(n), na pozadí \(nb))")
                }
            } else {
                self._fail += 1
                self._lastError = err?.localizedDescription ?? "?"
                let f = self._fail
                self.lock.unlock()
                if f <= 5 || f % 20 == 0 {
                    log("❌ Apple mapa selhala (\(stateName), \(ms) ms): \(err?.localizedDescription ?? "?")")
                }
            }
            self.lock.lock(); self.inFlight = false; self.lock.unlock()
        }
    }
}

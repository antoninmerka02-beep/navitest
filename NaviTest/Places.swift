import Foundation
import MapKit
import Combine

// MARK: - Místo (oblíbené, domov, práce, historie)
struct Place: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case home, work, favorite, history }
    var id = UUID()
    var kind: Kind
    var name: String
    var subtitle: String
    var lat: Double
    var lon: Double
    var date = Date()

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }

    func isSameSpot(_ o: Place) -> Bool {
        CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: o.lat, longitude: o.lon)) < 30
            && (name == o.name || kind == .home || kind == .work || o.kind == .home || o.kind == .work)
    }

    static func from(_ item: MKMapItem, kind: Kind = .history) -> Place {
        let pm = item.placemark
        let street = [pm.thoroughfare, pm.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let sub = [street.isEmpty ? nil : street, pm.locality].compactMap { $0 }.joined(separator: ", ")
        return Place(kind: kind, name: item.name ?? (street.isEmpty ? T("Place") : street), subtitle: sub,
                     lat: pm.coordinate.latitude, lon: pm.coordinate.longitude)
    }
}

/// Porovnávání bez ohledu na velikost písmen a diakritiku („tyr“ najde „Tyršova“).
func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "cs_CZ"))
}

// MARK: - Úložiště oblíbených a historie
final class PlacesStore: ObservableObject {
    @Published private(set) var favorites: [Place] = []   // home, work, favorite
    @Published private(set) var history: [Place] = []     // nejnovější první

    private let favKey = "places.favorites.v1"
    private let histKey = "places.history.v1"
    private let maxHistory = 40

    init() {
        favorites = load(favKey)
        history = load(histKey)
    }

    var home: Place? { favorites.first { $0.kind == .home } }
    var work: Place? { favorites.first { $0.kind == .work } }
    var others: [Place] { favorites.filter { $0.kind == .favorite } }

    func setHome(_ p: Place) { setSpecial(p, kind: .home) }
    func setWork(_ p: Place) { setSpecial(p, kind: .work) }

    private func setSpecial(_ p: Place, kind: Place.Kind) {
        favorites.removeAll { $0.kind == kind }
        var n = p
        n.id = UUID(); n.kind = kind; n.date = Date()
        favorites.insert(n, at: kind == .home ? 0 : min(1, favorites.count))
        save()
    }

    func addFavorite(_ p: Place) {
        guard !favorites.contains(where: { $0.kind == .favorite && $0.isSameSpot(p) }) else { return }
        var n = p
        n.id = UUID(); n.kind = .favorite; n.date = Date()
        favorites.append(n)
        save()
    }

    func remove(_ p: Place) {
        favorites.removeAll { $0.id == p.id }
        history.removeAll { $0.id == p.id }
        save()
    }

    func addHistory(_ p: Place) {
        guard p.kind == .history else { return }       // domov/práce/oblíbené do historie nepatří
        history.removeAll { $0.isSameSpot(p) }
        var n = p
        n.date = Date()
        history.insert(n, at: 0)
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        save()
    }

    func clearHistory() { history = []; save() }
    func clearAll() { favorites = []; history = []; save() }

    private func load(_ key: String) -> [Place] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([Place].self, from: d) else { return [] }
        return v
    }

    private func save() {
        if let d = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(d, forKey: favKey) }
        if let d = try? JSONEncoder().encode(history) { UserDefaults.standard.set(d, forKey: histKey) }
    }
}

// MARK: - Našeptávač
struct Suggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let place: Place?                         // historie / oblíbené – souřadnice už známe
    let completion: MKLocalSearchCompletion?  // návrh Apple Map – souřadnice se dohledají
}

final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()
    private var lastQuery = ""

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ q: String, near: CLLocation?) {
        lastQuery = q
        if let l = near {
            completer.region = MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 150_000, longitudinalMeters: 150_000)
        }
        let t = q.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            completer.cancel()
            results = []
        } else {
            completer.queryFragment = t
        }
    }

    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        results = c.results
    }

    func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    /// Historie a oblíbené nahoře (shoda od začátku, pak nejčerstvější), pod nimi Apple od nejpodobnějšího.
    func suggestions(query: String, store: PlacesStore) -> [Suggestion] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        if q.isEmpty {
            return store.history.prefix(6).map {
                Suggestion(id: "h-\($0.id)", title: $0.name, subtitle: $0.subtitle, place: $0, completion: nil)
            }
        }
        let own = (store.favorites + store.history).filter { fold($0.name + " " + $0.subtitle).contains(q) }
        let ranked = own.sorted { a, b in
            let pa = fold(a.name).hasPrefix(q), pb = fold(b.name).hasPrefix(q)
            if pa != pb { return pa }
            if (a.kind != .history) != (b.kind != .history) { return a.kind != .history }
            return a.date > b.date
        }
        var out: [Suggestion] = []
        var seen = Set<String>()
        for p in ranked.prefix(4) {
            let key = fold(p.name)
            if seen.insert(key).inserted {
                out.append(Suggestion(id: "p-\(p.id)", title: p.name, subtitle: p.subtitle, place: p, completion: nil))
            }
        }
        // Apple výsledky: nejdřív ty, které začínají zadaným textem (pořadí Apple zachováno)
        let prefix = results.filter { fold($0.title).hasPrefix(q) }
        let rest = results.filter { !fold($0.title).hasPrefix(q) }
        for c in (prefix + rest).prefix(10) {
            let key = fold(c.title)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(Suggestion(id: "c-\(c.title)|\(c.subtitle)", title: c.title, subtitle: c.subtitle, place: nil, completion: c))
        }
        return out
    }
}

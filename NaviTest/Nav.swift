import Foundation
import CoreLocation

/// Garmin TurnArrowIconType (pořadí ověřené z APK StreetCross 1.87).
enum TurnIcon {
    static let arriving: UInt8 = 0, arrivingL: UInt8 = 1, arrivingR: UInt8 = 2
    static let keepL: UInt8 = 6, keepR: UInt8 = 7, straight: UInt8 = 8
    static let exitL: UInt8 = 10, exitR: UInt8 = 11
    static let roundabout: UInt8 = 14
    static let sharpL: UInt8 = 32, sharpR: UInt8 = 33
    static let turnL: UInt8 = 34, turnR: UInt8 = 35
    static let uturnL: UInt8 = 36, uturnR: UInt8 = 37

    static func isRoundabout(_ i: UInt8) -> Bool { i >= 14 && i <= 31 }
    static func isArrival(_ i: UInt8) -> Bool { i <= 5 }

    /// SF Symbol pro panel v telefonu.
    static func symbol(_ i: UInt8) -> String {
        switch i {
        case 3...5: return "mappin.and.ellipse"
        case 0...2: return "flag.checkered"
        case 6, 10: return "arrow.up.left"
        case 7, 11: return "arrow.up.right"
        case 14...31: return "arrow.triangle.turn.up.right.circle"
        case 32: return "arrow.turn.down.left"
        case 33: return "arrow.turn.down.right"
        case 34: return "arrow.turn.up.left"
        case 35: return "arrow.turn.up.right"
        case 36, 37: return "arrow.uturn.down"
        default: return "arrow.up"
        }
    }

    /// Ikona kruháče podle úhlu objetého po kruhu (CZ jezdí proti směru hodinek):
    /// 90° = výjezd vpravo, 180° = rovně, 270° = vlevo, 360° = otočka. Ikony 15…22.
    static func roundabout(around: Double) -> UInt8 {
        let idx = min(8, max(1, Int((around / 45).rounded())))
        return UInt8(14 + idx)
    }

    static func name(_ i: UInt8) -> String {
        switch i {
        case 3, 4, 5: return T("waypoint")
        case 0: return T("destination")
        case 1: return T("destination on the left")
        case 2: return T("destination on the right")
        case 6: return T("keep left")
        case 7: return T("keep right")
        case 8: return T("straight")
        case 10: return T("exit left")
        case 11: return T("exit right")
        case 14: return T("roundabout")
        case 15...22: return TF("roundabout %ld°", Int(i - 14) * 45)
        case 32: return T("sharp left")
        case 33: return T("sharp right")
        case 34: return T("left")
        case 35: return T("right")
        case 36: return T("U-turn")
        case 37: return T("U-turn right")
        default: return TF("icon %ld", Int(i))
        }
    }
}

/// Položka seznamu odboček pro přístrojovku.
struct TurnItem {
    let icon: UInt8
    let leg: Double        // metry od předchozí odbočky
    let label: String
}

struct UpcomingItem {
    let icon: UInt8
    let dist: Double
    let text: String
}

/// Jeden „snímek“ navigace – z něj se skládají zprávy pro přístrojovku i obrázek mapy.
struct NavSnapshot {
    var guiding = true               // false = jen volná jízda (poloha bez trasy)
    var icon: UInt8 = TurnIcon.straight
    var toNext: Double = 0
    var road: String = ""
    var text: String = ""
    var lanes: [UInt8] = []
    var remaining: Double = 0
    var minutesLeft: Int = 0
    var currentRoad: String = ""
    var speedLimit: Float = 0         // 0 = neznámý (MapKit limity nedává)
    var etaHour: Int = 0
    var etaMinute: Int = 0
    var upcoming: [UpcomingItem] = []
    var maneuverIndex: Int = 0
    var arrived = false
    var street: String = ""          // čistý název ulice (pro hlas)
    var nextIcon: UInt8? = nil       // následující manévr (pro „poté …“)
    var nextGap: Double = 0          // vzdálenost mezi aktuálním a následujícím manévrem
    var rbExit: Int = 0              // kruháč: číslo výjezdu (0 = neznámé)
    var rbAround: Double = 180       // kruháč: úhel objetý po kruhu
    // Pro kreslení mapy (skutečná navigace)
    var position: CLLocationCoordinate2D? = nil
    var heading: Double = 0
    var routeAhead: [CLLocationCoordinate2D] = []
    var routeBehind: [CLLocationCoordinate2D] = []
    var maneuverPoint: CLLocationCoordinate2D? = nil
    var destination: CLLocationCoordinate2D? = nil
    var along: Double = 0                // metry od začátku trasy
    var waypoints: [CLLocationCoordinate2D] = []   // zbývající průjezdní body (špendlíky)
}

/// Vzdálenost na hodnotu + jednotku jako StreetCross (m pod 1 km, jinak km).
func formatDistance(_ meters: Double) -> (Float, String) {
    if meters < 1000 { return (Float((meters / 10).rounded() * 10), "m") }
    return (Float((meters / 100).rounded() / 10), "km")
}

func etaComponents(secondsFromNow: Double) -> (Int, Int) {
    let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(secondsFromNow))
    return (c.hour ?? 0, c.minute ?? 0)
}

// MARK: - Den / noc podle slunce (NOAA, přesnost na pár minut stačí)
/// Výška slunce nad obzorem ve stupních.
func sunElevation(lat: Double, lon: Double, date: Date = Date()) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let c = cal.dateComponents([.year, .hour, .minute, .second], from: date)
    let day = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
    let hour = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    let g = 2 * Double.pi / 365 * (day - 1 + (hour - 12) / 24)
    let eqTime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
    let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g) + 0.000907 * sin(2 * g)
        - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
    let tst = hour * 60 + eqTime + 4 * lon
    let ha = (tst / 4 - 180) * Double.pi / 180
    let latR = lat * Double.pi / 180
    let cosZ = sin(latR) * sin(decl) + cos(latR) * cos(decl) * cos(ha)
    return 90 - acos(max(-1, min(1, cosZ))) * 180 / Double.pi
}

/// Noc = slunce víc než 3° pod obzorem (po soumraku).
func isNight(at c: CLLocationCoordinate2D?, date: Date = Date()) -> Bool {
    guard let c = c else {
        let h = Calendar.current.component(.hour, from: date)
        return h < 6 || h >= 20
    }
    return sunElevation(lat: c.latitude, lon: c.longitude, date: date) < -3
}

// MARK: - Text pro přístrojovku
/// Zkrátí dlouhé názvy ulic běžnými zkratkami (přístrojovka zalamuje po písmenech).
func dashText(_ s: String) -> String {
    var t = s
    if let comma = t.range(of: ", ") { t = String(t[..<comma.lowerBound]) }   // „D 55, směr Olomouc…“ → „D 55“
    let repl: [(String, String)] = [
        ("třída ", "tř. "), ("Třída ", "Tř. "), ("náměstí", "nám."), ("Náměstí", "Nám."),
        ("nábřeží", "nábř."), ("Nábřeží ", "Nábř. "), ("Silnice ", ""), ("ulice ", "ul. "),
    ]
    for (a, b) in repl { t = t.replacingOccurrences(of: a, with: b) }
    return t.trimmingCharacters(in: .whitespaces)
}

enum DayNightMode: String, Codable, CaseIterable, Identifiable {
    case auto, day, night
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return T("Automatic")
        case .day: return T("Day")
        case .night: return T("Night")
        }
    }
}

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

    static func name(_ i: UInt8) -> String {
        switch i {
        case 0: return "cíl"; case 1: return "cíl vlevo"; case 2: return "cíl vpravo"
        case 6: return "držet vlevo"; case 7: return "držet vpravo"; case 8: return "rovně"
        case 10: return "sjezd vlevo"; case 11: return "sjezd vpravo"; case 14: return "kruháč"
        case 32: return "ostře vlevo"; case 33: return "ostře vpravo"
        case 34: return "vlevo"; case 35: return "vpravo"
        case 36: return "otočka"; case 37: return "otočka P"
        default: return "ikona \(i)"
        }
    }
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
    // Pro kreslení mapy (skutečná navigace)
    var position: CLLocationCoordinate2D? = nil
    var heading: Double = 0
    var routeAhead: [CLLocationCoordinate2D] = []
    var routeBehind: [CLLocationCoordinate2D] = []
    var maneuverPoint: CLLocationCoordinate2D? = nil
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

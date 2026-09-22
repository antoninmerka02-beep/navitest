import Foundation

/// Falešná trasa po Zlíně – jen aby bylo co posílat. Jede „50 km/h“ a dokola.
struct SimManeuver {
    let icon: UInt8        // Garmin TurnArrowIconType ordinal
    let road: String       // ulice, na kterou se odbočuje
    let length: Double     // metry od předchozího manévru
    let text: String       // text pro turn-by-turn seznam
    let lanes: [UInt8]     // 1 rovně, 2/3 šikmo P/L, 4/5 vpravo/vlevo, 7–12 = šedé (nedoporučené)
}

struct SimSnapshot {
    let maneuver: SimManeuver
    let toNext: Double
    let remaining: Double
    let minutesLeft: Int
    let currentRoad: String
    let speedLimit: Float
    let eta: (hour: Int, minute: Int)
    let upcoming: [(SimManeuver, Double)]   // manévr + vzdálenost od aktuální polohy
    let index: Int
}

final class RouteSimulator {
    let route: [SimManeuver] = [
        .init(icon: 34, road: "Třída Tomáše Bati", length: 600, text: "Vlevo na Třídu Tomáše Bati", lanes: [3, 7, 7]),
        .init(icon: 35, road: "Zarámí", length: 450, text: "Vpravo na Zarámí", lanes: []),
        .init(icon: 14, road: "Gahurova", length: 700, text: "Kruhový objezd, 2. výjezd", lanes: []),
        .init(icon: 8, road: "Dlouhá", length: 900, text: "Pokračujte rovně", lanes: [1, 1]),
        .init(icon: 6, road: "R49", length: 1500, text: "Držte se vlevo na R49", lanes: [3, 9]),
        .init(icon: 36, road: "Otočka", length: 400, text: "Otočte se", lanes: []),
        .init(icon: 0, road: "Cíl", length: 800, text: "Cíl", lanes: []),
    ]
    let speed = 13.9 // m/s ≈ 50 km/h
    private(set) var index = 0
    private(set) var toNext: Double

    init() { toNext = route[0].length }

    func tick(_ dt: Double) {
        toNext -= speed * max(0, min(dt, 5))
        if toNext <= 0 {
            index = (index + 1) % route.count
            toNext = route[index].length
        }
    }

    func snapshot() -> SimSnapshot {
        var remaining = toNext
        var upcoming: [(SimManeuver, Double)] = [(route[index], toNext)]
        var acc = toNext
        if index + 1 < route.count {
            for m in route[(index + 1)...] {
                remaining += m.length
                acc += m.length
                upcoming.append((m, acc))
            }
        }
        let minutes = Int((remaining / speed / 60).rounded(.up))
        let eta = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(remaining / speed))
        return SimSnapshot(
            maneuver: route[index],
            toNext: toNext,
            remaining: remaining,
            minutesLeft: minutes,
            currentRoad: index == 0 ? "Zlínská" : route[index - 1].road,
            speedLimit: index % 2 == 0 ? 50 : 90,
            eta: (eta.hour ?? 0, eta.minute ?? 0),
            upcoming: Array(upcoming.prefix(5)),
            index: index
        )
    }
}

/// Vzdálenost na hodnotu + jednotku tak, jak to dělá StreetCross (m pod 1 km, jinak km).
func formatDistance(_ meters: Double) -> (Float, String) {
    if meters < 1000 { return (Float((meters / 10).rounded() * 10), "m") }
    return (Float((meters / 100).rounded() / 10), "km")
}

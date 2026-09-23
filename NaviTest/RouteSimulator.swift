import Foundation

/// Falešná trasa – jede „50 km/h“ dokola, aby bylo co posílat i bez skutečné trasy.
struct SimManeuver {
    let icon: UInt8
    let road: String
    let length: Double
    let text: String
    let lanes: [UInt8]   // 1 rovně, 2/3 šikmo P/L, 4/5 vpravo/vlevo, 7–12 = šedé (nedoporučené)
}

final class RouteSimulator {
    let route: [SimManeuver] = [
        .init(icon: TurnIcon.turnL, road: "Třída Tomáše Bati", length: 600, text: "Vlevo na Třídu Tomáše Bati", lanes: [3, 7, 7]),
        .init(icon: TurnIcon.turnR, road: "Zarámí", length: 450, text: "Vpravo na Zarámí", lanes: []),
        .init(icon: TurnIcon.roundabout(around: 180), road: "2. výjezd · Gahurova", length: 700, text: "Kruhový objezd, 2. výjezd", lanes: []),
        .init(icon: TurnIcon.straight, road: "Dlouhá", length: 900, text: "Pokračujte rovně", lanes: [1, 1]),
        .init(icon: TurnIcon.keepL, road: "R49", length: 1500, text: "Držte se vlevo na R49", lanes: [3, 9]),
        .init(icon: TurnIcon.exitR, road: "Otrokovice", length: 1200, text: "Sjeďte vpravo", lanes: [7, 2]),
        .init(icon: TurnIcon.uturnL, road: "Otočka", length: 400, text: "Otočte se", lanes: []),
        .init(icon: TurnIcon.arrivingR, road: "Cíl", length: 800, text: "Cíl je vpravo", lanes: []),
    ]
    private(set) var index = 0
    private(set) var toNext: Double
    private var speed = 13.9          // m/s ≈ 50 km/h
    private var phase = 0.0

    init() { toNext = route[0].length }

    func tick(_ dt: Double) {
        let d = max(0, min(dt, 5))
        // Posledních 150 m před odbočkou zpomalí, ať jsou na displeji vidět i malé vzdálenosti.
        speed = toNext < 150 ? 5.0 : 13.9
        toNext -= speed * d
        phase += d
        if toNext <= 0 {
            index = (index + 1) % route.count
            toNext = route[index].length
        }
    }

    func snapshot() -> NavSnapshot {
        var s = NavSnapshot()
        let m = route[index]
        s.icon = m.icon; s.toNext = toNext; s.road = m.road; s.text = m.text; s.lanes = m.lanes
        if TurnIcon.isRoundabout(m.icon) { s.rbExit = 2; s.rbAround = 180 }
        var remaining = toNext
        var items: [UpcomingItem] = [UpcomingItem(icon: m.icon, dist: toNext, text: m.text)]
        var acc = toNext
        if index + 1 < route.count {
            for n in route[(index + 1)...] {
                remaining += n.length; acc += n.length
                items.append(UpcomingItem(icon: n.icon, dist: acc, text: n.text))
            }
        }
        s.remaining = remaining
        let secs = remaining / 13.9
        s.minutesLeft = Int((secs / 60).rounded(.up))
        (s.etaHour, s.etaMinute) = etaComponents(secondsFromNow: secs)
        s.currentRoad = index == 0 ? "Zlínská" : route[index - 1].road
        s.speedLimit = index % 2 == 0 ? 50 : 90
        s.upcoming = Array(items.prefix(5))
        s.maneuverIndex = index
        return s
    }
}

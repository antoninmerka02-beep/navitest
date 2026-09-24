import Foundation

// NaviLite protokol (Garmin/Yamaha CCU). Formáty zpráv jsou ověřené proti Garminově
// nativní knihovně libnaviliteprotocol.so (StreetCross 1.87) – viz NL.selfTest().

func le32(_ x: UInt32) -> [UInt8] {
    [UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF), UInt8((x >> 16) & 0xFF), UInt8((x >> 24) & 0xFF)]
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// UTF-8 bajty řetězce, oříznuté na hranici znaku (aby se nerozsekla diakritika).
func utf8Capped(_ s: String, maxBytes: Int = 63) -> [UInt8] {
    var out: [UInt8] = []
    for ch in s {
        let e = Array(String(ch).utf8)
        if out.count + e.count > maxBytes { break }
        out += e
    }
    return out
}

struct ByteWriter {
    var b: [UInt8] = []
    mutating func u8(_ v: Int) { b.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { u8(v); u8(v >> 8) }
    mutating func i32(_ v: Int) { b += le32(UInt32(truncatingIfNeeded: v)) }
    mutating func f32(_ v: Float) { b += le32(v.bitPattern) }
    mutating func raw(_ d: [UInt8]) { b += d }
}

struct NLMessage {
    let svc: UInt8
    let pdt: UInt8
    let payload: [UInt8]
    var frame: [UInt8] { NL.frame(svc: svc, pdt: pdt, payload) }
}

struct InFrame {
    let frameType: UInt8
    let svc: UInt8
    let pdt: UInt8
    let payload: [UInt8]
}

enum NL {
    static let magic: [UInt8] = [0x6E, 0x41, 0x6C, 0x40] // "nAl@"
    static let frameTypePhone: UInt8 = 6
    static let pdtValue: UInt8 = 0
    static let pdtPointer: UInt8 = 1

    // MARK: CRC-32/MPEG-2 (poly 0x04C11DB7, init 0xFFFFFFFF, bez reflexe) přes magic+hlavičku+payload
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = (c & 0x8000_0000) != 0 ? ((c << 1) ^ 0x04C1_1DB7) : (c << 1) }
        return c
    }

    static func crc32mpeg2(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = (c << 8) ^ table[Int(((c >> 24) ^ UInt32(b)) & 0xFF)] }
        return c
    }

    /// magic(4) | verze(1) | frameType(1) | služba(1) | délka(4 LE) | pdt(1) | CRC(4 LE) | payload
    static func frame(svc: UInt8, pdt: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var h = magic
        h += [1, frameTypePhone, svc]
        h += le32(UInt32(payload.count))
        h.append(pdt)
        let crc = crc32mpeg2(h + payload)
        return h + le32(crc) + payload
    }

    // MARK: Handshake
    static func esnAck() -> NLMessage { .init(svc: 81, pdt: pdtValue, payload: [1, 0]) }
    /// appVersion 1820 (0x071c) – stejné bajty jako Pillion, ověřeno na motorkách.
    static func authRequest() -> NLMessage {
        .init(svc: 33, pdt: pdtPointer, payload: [0x1C, 0x07, 0x00, 0x01, 0, 0, 0, 0])
    }
    /// SEC_DATA = (číslo dílu + 4B nonce) XOR 0x0A → odpovídáme de-obfuskovaným nonce.
    static func secDataAck(seed: [UInt8]) -> NLMessage? {
        guard seed.count >= 4 else { return nil }
        let nonce = seed.suffix(4).map { $0 ^ 0x0A }
        return .init(svc: 84, pdt: pdtPointer, payload: nonce)
    }
    static func partNumber(seed: [UInt8]) -> String {
        guard seed.count > 4 else { return "?" }
        let bytes = seed.prefix(seed.count - 4).map { $0 ^ 0x0A }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Stavové zprávy (VALUE, 2 bajty)
    /// 2 = NAV_STATUS, 10 = HOME, 11 = OFFICE, 12 = APP_SETTING / init setup complete, 13 = GPS
    static func flag(_ svc: UInt8, _ on: Bool) -> NLMessage { .init(svc: svc, pdt: pdtValue, payload: [on ? 1 : 0, 0]) }
    /// 1 = den, 2 = noc (0 = auto Garmin knihovna odmítá)
    static func dayNight(_ mode: UInt8) -> NLMessage { .init(svc: 31, pdt: pdtValue, payload: [mode, 0]) }

    static func zoom(current: Int, lo: Int, hi: Int, label: String, show: Bool) -> NLMessage {
        let l = utf8Capped(label, maxBytes: 32)
        var w = ByteWriter()
        w.u8(max(0, current - lo)); w.u8(max(0, hi - lo)); w.u8(l.count); w.u8(show ? 1 : 0); w.raw(l)
        return .init(svc: 14, pdt: pdtPointer, payload: w.b)
    }

    // MARK: Navigační data
    static func currentRoad(_ s: String) -> NLMessage { .init(svc: 3, pdt: pdtPointer, payload: utf8Capped(s, maxBytes: 64)) }

    static func speedLimit(_ v: Float, unit: String) -> NLMessage {
        let u = utf8Capped(unit, maxBytes: 16)
        var w = ByteWriter(); w.f32(v); w.u8(u.count); w.raw(u)
        return .init(svc: 17, pdt: pdtPointer, payload: w.b)
    }

    static func eta(hour: Int, minute: Int) -> NLMessage {
        var w = ByteWriter(); w.i32(hour * 60 + minute)
        return .init(svc: 1, pdt: pdtPointer, payload: w.b)
    }

    /// Služba 19 – bohatá navigační info (R9 / MT-09 / modely 006-B4160, 006-B4920).
    static func navInfo(icon: UInt8, dist: Float, unit: String, road: String,
                        remain: Float, remainUnit: String, minutes: Int, lanes: [UInt8]) -> NLMessage {
        let u1 = utf8Capped(unit, maxBytes: 16), r = utf8Capped(road), u2 = utf8Capped(remainUnit, maxBytes: 16)
        let ln = Array(lanes.prefix(5))
        var w = ByteWriter()
        w.u8(Int(icon)); w.f32(dist); w.u8(u1.count); w.u8(r.count)
        w.f32(remain); w.u8(u2.count); w.i32(minutes); w.u8(ln.count)
        w.raw(u1); w.raw(r); w.raw(u2); w.raw(ln)
        return .init(svc: 19, pdt: pdtPointer, payload: w.b)
    }

    /// Služba 4 – jednodušší varianta (starší přístrojovky 006-B3952).
    static func nextTurn(icon: UInt8, dist: Float, unit: String, road: String) -> NLMessage {
        let u = utf8Capped(unit, maxBytes: 16), r = utf8Capped(road)
        var w = ByteWriter()
        w.u8(Int(icon)); w.f32(dist); w.u8(u.count); w.u8(r.count); w.raw(u); w.raw(r)
        return .init(svc: 4, pdt: pdtPointer, payload: w.b)
    }

    // MARK: Turn-by-turn seznam (obsah typu 2)
    static func tbtListUpdate(count: Int, hasMore: Bool) -> NLMessage {
        var w = ByteWriter(); w.u16(count); w.u8(hasMore ? 1 : 0)
        return .init(svc: 5, pdt: pdtPointer, payload: w.b)
    }
    static func tbtItem(index: Int, icon: UInt8, dist: Float, unit: String, text: String) -> NLMessage {
        let u = utf8Capped(unit, maxBytes: 16), t = utf8Capped(text)
        var w = ByteWriter()
        w.u16(index); w.u8(Int(icon)); w.u8(t.count); w.u8(u.count); w.f32(dist); w.raw(u); w.raw(t)
        return .init(svc: 97, pdt: pdtPointer, payload: w.b)
    }
    static func activeTbt(_ i: Int) -> NLMessage {
        var w = ByteWriter(); w.u16(i)
        return .init(svc: 6, pdt: pdtValue, payload: w.b)
    }

    // MARK: Start trasy – bez toho přístrojovka „neví“ o trase (prázdný levý sloupec, „Route navigation unavailable“)
    /// Průběh výpočtu trasy v %: 0 … 100, a -1 (0xFF) = výpočet dokončen.
    static func routeCalcProgress(_ percent: Int) -> NLMessage {
        .init(svc: 15, pdt: pdtValue, payload: [UInt8(truncatingIfNeeded: percent), 0])
    }
    /// Počet průjezdních bodů trasy.
    static func viaCount(_ n: Int) -> NLMessage {
        var w = ByteWriter(); w.u16(n)
        return .init(svc: 18, pdt: pdtValue, payload: w.b)
    }

    // MARK: Oblíbená místa (obsah typu 3) – seznam pro výběr cíle joystickem
    /// Hlavička seznamu: počet položek.
    static func favPoiUpdate(count: Int) -> NLMessage {
        var w = ByteWriter(); w.u16(count); w.u8(0)
        return .init(svc: 7, pdt: pdtPointer, payload: w.b)
    }
    /// Položka: index položky, index seznamu (0/1 střídavě), směr (1 = rovně, po 45° po směru hodinek), vzdálenost, název.
    static func favPoiData(list: Int, item: Int, direction: UInt8, dist: Float, unit: String, name: String) -> NLMessage {
        let u = utf8Capped(unit, maxBytes: 16), n = utf8Capped(name)
        var w = ByteWriter()
        w.u16(item); w.u16(list); w.u8(Int(direction)); w.u8(n.count); w.u8(u.count); w.f32(dist); w.raw(u); w.raw(n)
        return .init(svc: 98, pdt: pdtPointer, payload: w.b)
    }

    // MARK: Obraz (obsah typu 1)
    /// imageType 3 = rozšířený navigační pohled, sekvence u16 LE, pak baseline JPEG 480×240.
    static func image(seq: Int, jpeg: [UInt8], imageType: UInt8 = 3) -> NLMessage {
        var w = ByteWriter(); w.u8(Int(imageType)); w.u16(seq); w.raw(jpeg)
        return .init(svc: 0, pdt: pdtPointer, payload: w.b)
    }
    static func imageStopped() -> NLMessage { .init(svc: 20, pdt: pdtValue, payload: []) }

    // MARK: Varování (služba 9) – přístrojovka je zobrazí nativně
    /// Typ události: 0 doprava, 1 rychlost, 2 radar, 3 hranice, 4 škola, 5 jiné. Podtyp 126 = nedefinováno.
    static func naviEvent(type: UInt8, text: String, show: Bool, subType: UInt8 = 126) -> NLMessage {
        let t = utf8Capped(text)
        var w = ByteWriter()
        w.u8(Int(type)); w.u8(Int(subType)); w.u8(show ? 1 : 0); w.u8(t.count); w.raw(t)
        return .init(svc: 9, pdt: pdtPointer, payload: w.b)
    }
    /// Radar přesně jako StreetCross: text "limit;vzdálenost" (např. "50 km/h;300 m"),
    /// podtyp = druh radaru: 0 pevný, 1 dočasný, 2 mobilní, 3 úsekové, 4 proměnný, 5 červená, 7 mobilní zóna.
    static func speedCamera(limit: String, distance: String, cameraType: UInt8, show: Bool) -> NLMessage {
        naviEvent(type: 2, text: "\(limit);\(distance)", show: show, subType: cameraType)
    }
    /// Zrušení radaru – přesně jako StreetCross ("" ; "" s podtypem 126).
    static func speedCameraClear() -> NLMessage { naviEvent(type: 2, text: ";", show: false) }
    /// Škola: přístrojovka sama kreslí „School Zone“, text je jen vzdálenost.
    static func schoolZone(distance: String, show: Bool) -> NLMessage { naviEvent(type: 4, text: distance, show: show) }
    /// Hranice: podtyp 42 = stát, 41 = region; text je vzdálenost.
    static func border(country: Bool, distance: String) -> NLMessage {
        naviEvent(type: 3, text: distance, show: true, subType: country ? 42 : 41)
    }
    /// Zrušení hranice – Garmin ruší s podtypem 126 (ne 42!), jinak se lišta varování zasekne.
    static func borderClear() -> NLMessage { naviEvent(type: 3, text: "", show: false) }
    static func schoolZoneClear() -> NLMessage { schoolZone(distance: "", show: false) }
    /// Překročení rychlosti – Garmin posílá typ 1 s prázdným textem.
    static func speedingEvent() -> NLMessage { naviEvent(type: 1, text: "", show: true) }

    // MARK: Jména služeb do logu
    static func name(_ svc: UInt8) -> String {
        switch svc {
        case 0: return "IMAGE"
        case 1: return "ETA"
        case 2: return "NAV_STATUS"
        case 3: return "CUR_ROAD"
        case 4: return "NEXT_TURN_DIST"
        case 5: return "TBT_LIST"
        case 6: return "ACTIVE_TBT"
        case 9: return "NAVI_EVENT_TEXT"
        case 12: return "APP_SETTING"
        case 13: return "GPS_STATUS"
        case 14: return "ZOOM_LEVEL"
        case 17: return "SPEED_LIMIT"
        case 19: return "NAVIGATION_INFO"
        case 20: return "IMAGE_STOPPED"
        case 31: return "DAY_NIGHT"
        case 48: return "START_ROUTE_REQ"
        case 49: return "STOP_ROUTE_REQ"
        case 50: return "SKIP_WAYPOINT_REQ"
        case 51: return "ZOOM_IN_REQ"
        case 52: return "ZOOM_OUT_REQ"
        case 53: return "GO_HOME_REQ"
        case 54: return "GO_OFFICE_REQ"
        case 55: return "START_CONTENT_REQ"
        case 56: return "STOP_CONTENT_REQ"
        case 65: return "VEHICLE_SPEED"
        case 66: return "ESN"
        case 69: return "SYSINFO"
        case 70: return "DIALOG_SELECT"
        case 80: return "IMAGE_ACK"
        case 82: return "AUTH_ACK"
        case 83: return "SEC_DATA"
        case 97: return "TBT_DATA"
        case 98: return "FAV_POI_DATA"
        default: return "svc\(svc)"
        }
    }

    static func contentName(_ t: UInt8) -> String {
        switch t {
        case 1: return "MAPA (obrázky)"
        case 2: return "TURN-BY-TURN seznam"
        case 3: return "oblíbená místa"
        case 4: return "čerpací stanice"
        case 11: return "test propustnosti"
        default: return "neznámý \(t)"
        }
    }

    // MARK: Self-test – očekávané payloady vygenerovala Garminova vlastní knihovna
    static func selfTest() -> (passed: Int, total: Int, lines: [String]) {
        let cases: [(String, NLMessage, String)] = [
            ("NAVIGATION_INFO (19)",
             navInfo(icon: 34, dist: 350, unit: "m", road: "Třída Tomáše Bati", remain: 12.5, remainUnit: "km", minutes: 17, lanes: [1, 1, 5]),
             "220000af430115000048410211000000036d54c599c3ad646120546f6dc3a1c5a16520426174696b6d010105"),
            ("NEXT_TURN_DIST (4)", nextTurn(icon: 34, dist: 350, unit: "m", road: "Zlínská"),
             "220000af4301096d5a6cc3ad6e736bc3a1"),
            ("TBT_LIST (5)", tbtListUpdate(count: 3, hasMore: false), "030000"),
            ("TBT_DATA (97)", tbtItem(index: 1, icon: 35, dist: 1.2, unit: "km", text: "Vpravo na D55"),
             "0100230d029a99993f6b6d56707261766f206e6120443535"),
            ("ACTIVE_TBT (6)", activeTbt(0), "0000"),
            ("ETA (1)", eta(hour: 14, minute: 35), "6b030000"),
            ("SPEED_LIMIT (17)", speedLimit(50, unit: "km/h"), "00004842046b6d2f68"),
            ("CUR_ROAD (3)", currentRoad("Zlínská"), "5a6cc3ad6e736bc3a1"),
            ("ZOOM (14)", zoom(current: 7, lo: 0, hi: 25, label: "200 m", show: true), "07190501323030206d"),
            ("IMAGE (0)", image(seq: 258, jpeg: [0xFF, 0xD8, 0xFF, 0xD9]), "030201ffd8ffd9"),
            ("RADAR úsekové (9)", speedCamera(limit: "90 km/h", distance: "1.2 km", cameraType: 3, show: true), "0203010e3930206b6d2f683b312e32206b6d"),
            ("RADAR červená (9)", speedCamera(limit: "50 km/h", distance: "", cameraType: 5, show: true), "020501083530206b6d2f683b"),
            ("RADAR zrušit (9)", speedCameraClear(), "027e00013b"),
            ("ŠKOLA 200 m (9)", schoolZone(distance: "200 m", show: true), "047e0105323030206d"),
            ("HRANICE (9)", border(country: true, distance: "2 km"), "032a010432206b6d"),
            ("HRANICE zrušit (9)", borderClear(), "037e0000"),
            ("ŠKOLA zrušit (9)", schoolZoneClear(), "047e0000"),
            ("RYCHLOST (9)", speedingEvent(), "017e0100"),
            ("OBLÍBENÉ počet (7)", favPoiUpdate(count: 3), "030000"),
            ("VÝPOČET TRASY 0 % (15)", routeCalcProgress(0), "0000"),
            ("VÝPOČET TRASY 100 % (15)", routeCalcProgress(100), "6400"),
            ("VÝPOČET TRASY hotovo (15)", routeCalcProgress(-1), "ff00"),
            ("PRŮJEZDNÍ BODY (18)", viaCount(300), "2c01"),
            ("OBLÍBENÉ položka (98)", favPoiData(list: 1, item: 2, direction: 3, dist: 2.5, unit: "km", name: "Domů"),
             "02000100030502000020406b6d446f6dc5af"),
        ]
        var lines: [String] = []
        var ok = 0
        for (label, msg, expected) in cases {
            let got = msg.payload.hex
            if got == expected { ok += 1; lines.append("✅ \(label)") }
            else { lines.append("❌ \(label)\n   očekáváno \(expected)\n   máme      \(got)") }
        }
        // CRC vektor zachycený z reálné komunikace (Pillion): SEC_DATA_ACK b0a04756 → CRC 24f0735b
        let f = frame(svc: 84, pdt: pdtPointer, [0xB0, 0xA0, 0x47, 0x56])
        let crcOK = Array(f[12..<16]).hex == "24f0735b"
        if crcOK { ok += 1; lines.append("✅ CRC rámce") } else { lines.append("❌ CRC rámce: \(Array(f[12..<16]).hex)") }
        return (ok, cases.count + 1, lines)
    }
}

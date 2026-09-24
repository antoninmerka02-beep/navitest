import Foundation
import AVFoundation

struct VoiceSettings: Codable {
    var enabled = true
    var streetNames = true
    var volume: Double = 1.0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoiceSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        streetNames = (try? c.decodeIfPresent(Bool.self, forKey: .streetNames)) ?? d.streetNames
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? d.volume
    }
}

/// Hlasové pokyny přes vestavěný převod textu na řeč iPhonu (funguje na pozadí, jde do helmy přes intercom).
/// Volá se z hlavního vlákna při každé nové poloze.
final class VoiceGuide: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var settings = VoiceSettings()

    // Co už bylo u aktuálního manévru řečeno: 1 = z dálky, 2 = před odbočkou, 3 = teď
    private var maneuverKey = ""
    private var stage = 0
    private var arrivedSpoken = false
    private var routeGen = -1

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Veřejné
    func reset() {
        maneuverKey = ""
        stage = 0
        arrivedSpoken = false
        routeGen = -1
        synth.stopSpeaking(at: .immediate)
    }

    /// Nová trasa / přepočet.
    func routeStarted(generation: Int, reroute: Bool) {
        guard generation != routeGen else { return }
        routeGen = generation
        maneuverKey = ""
        stage = 0
        arrivedSpoken = false
        if reroute { say(phrase(.recalculated)) }
    }

    func update(_ s: NavSnapshot, speed: Double) {
        guard settings.enabled, s.guiding else { return }
        if s.arrived {
            if !arrivedSpoken { arrivedSpoken = true; say(arrivalNow(s.icon)) }
            return
        }
        let key = "\(s.maneuverIndex)|\(s.icon)|\(s.road)"
        if key != maneuverKey { maneuverKey = key; stage = 0 }

        let v = max(8.0, speed)                      // m/s, ve stoje počítáme jako ~30 km/h
        let nowD = max(30.0, v * 4)
        let nearD = max(150.0, v * 12)
        let farD = min(2000.0, max(400.0, v * 35))
        let d = s.toNext

        if d <= nowD {
            if stage < 3 { stage = 3; say(instruction(s, distance: nil)) }
        } else if d <= nearD {
            if stage < 2 { stage = 2; say(instruction(s, distance: d)) }
        } else if d <= farD {
            if stage < 1 && d > nearD * 1.4 { stage = 1; say(instruction(s, distance: d)) }
        }
    }

    func sample() {
        var s = NavSnapshot()
        s.icon = TurnIcon.turnL
        s.street = L10n.lang == .cs ? "Třída Tomáše Bati" : "Main Street"
        s.road = s.street
        say(instruction(s, distance: 300))
    }

    // MARK: Řeč
    private func say(_ text: String) {
        guard !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let u = AVSpeechUtterance(string: text)
        u.voice = bestVoice(L10n.lang.speechCode)
        u.volume = Float(min(1, max(0.1, settings.volume)))
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
        log("🔊 \(text)")
    }

    private func bestVoice(_ code: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(code.prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let exact = all.filter { $0.language == code }
        let pool = exact.isEmpty ? all : exact
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: code)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Skládání vět
    private var cs: Bool { L10n.lang == .cs }

    private enum Fixed { case recalculated }

    private func phrase(_ f: Fixed) -> String {
        switch f {
        case .recalculated: return cs ? "Přepočítávám trasu." : "Recalculating."
        }
    }

    /// „Za 300 metrů odbočte vlevo na X“ / „Odbočte vlevo na X“ (distance nil = teď).
    private func instruction(_ s: NavSnapshot, distance: Double?) -> String {
        let action = actionPhrase(s)
        var text: String
        if let d = distance {
            text = distancePhrase(d) + " " + lowerFirst(action)
        } else {
            text = (cs ? "Nyní " : "Now ") + lowerFirst(action)
        }
        if let n = s.nextIcon, s.nextGap < 150, !TurnIcon.isArrival(n) {
            text += (cs ? ", poté " : ", then ") + lowerFirst(shortAction(n))
        }
        return text + "."
    }

    private func arrivalNow(_ icon: UInt8) -> String {
        switch icon {
        case 1: return cs ? "Dorazili jste do cíle. Cíl je vlevo." : "You have arrived. Your destination is on the left."
        case 2: return cs ? "Dorazili jste do cíle. Cíl je vpravo." : "You have arrived. Your destination is on the right."
        default: return cs ? "Dorazili jste do cíle." : "You have arrived at your destination."
        }
    }

    private func distancePhrase(_ m: Double) -> String {
        if m < 1000 {
            let r = m >= 300 ? (m / 100).rounded() * 100 : max(50, (m / 50).rounded() * 50)
            return cs ? "Za \(Int(r)) metrů" : "In \(Int(r)) meters"
        }
        let km = (m / 100).rounded() / 10
        if km == km.rounded() {
            let k = Int(km)
            if cs {
                let unit = k == 1 ? "kilometr" : (k >= 2 && k <= 4 ? "kilometry" : "kilometrů")
                return "Za \(k) \(unit)"
            }
            return k == 1 ? "In 1 kilometer" : "In \(k) kilometers"
        }
        let s = String(format: "%.1f", km)
        return cs ? "Za \(s.replacingOccurrences(of: ".", with: ",")) kilometru" : "In \(s) kilometers"
    }

    private func onto(_ s: NavSnapshot) -> String {
        guard settings.streetNames, !s.street.isEmpty else { return "" }
        return cs ? " na \(s.street)" : " onto \(s.street)"
    }

    private func actionPhrase(_ s: NavSnapshot) -> String {
        let i = s.icon
        if TurnIcon.isRoundabout(i) {
            let n = s.rbExit
            if n >= 1 && n <= 6 {
                let csOrd = ["prvním", "druhým", "třetím", "čtvrtým", "pátým", "šestým"][n - 1]
                let enOrd = ["first", "second", "third", "fourth", "fifth", "sixth"][n - 1]
                return cs ? "Na kruhovém objezdu vyjeďte \(csOrd) výjezdem\(onto(s))"
                          : "At the roundabout, take the \(enOrd) exit\(onto(s))"
            }
            let a = s.rbAround
            let dir: String
            if a < 135 { dir = cs ? "vpravo" : "right" }
            else if a <= 225 { dir = cs ? "rovně" : "straight on" }
            else if a < 330 { dir = cs ? "vlevo" : "left" }
            else { dir = cs ? "zpět" : "back" }
            return cs ? "Na kruhovém objezdu pokračujte \(dir)\(onto(s))" : "At the roundabout, go \(dir)\(onto(s))"
        }
        if TurnIcon.isArrival(i) {
            switch i {
            case 1: return cs ? "Dorazíte do cíle, cíl je vlevo" : "You will arrive, destination on the left"
            case 2: return cs ? "Dorazíte do cíle, cíl je vpravo" : "You will arrive, destination on the right"
            default: return cs ? "Dorazíte do cíle" : "You will arrive at your destination"
            }
        }
        return shortAction(i) + onto(s)
    }

    private func shortAction(_ i: UInt8) -> String {
        switch i {
        case 34: return cs ? "Odbočte vlevo" : "Turn left"
        case 35: return cs ? "Odbočte vpravo" : "Turn right"
        case 32: return cs ? "Odbočte ostře vlevo" : "Turn sharp left"
        case 33: return cs ? "Odbočte ostře vpravo" : "Turn sharp right"
        case 6: return cs ? "Držte se vlevo" : "Keep left"
        case 7: return cs ? "Držte se vpravo" : "Keep right"
        case 10: return cs ? "Sjeďte vlevo" : "Take the exit on the left"
        case 11: return cs ? "Sjeďte vpravo" : "Take the exit on the right"
        case 36, 37: return cs ? "Otočte se" : "Make a U-turn"
        case 14...31: return cs ? "Vjeďte na kruhový objezd" : "Enter the roundabout"
        case 0...5: return cs ? "Dorazíte do cíle" : "You will arrive"
        default: return cs ? "Pokračujte rovně" : "Continue straight"
        }
    }

    private func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + String(s.dropFirst())
    }
}

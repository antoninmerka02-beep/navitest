import Foundation
import AVFoundation

enum VoiceLanguage: String, Codable, CaseIterable, Identifiable {
    case app, en, cs
    var id: String { rawValue }
    var label: String {
        switch self {
        case .app: return T("Same as app")
        case .en: return "English"
        case .cs: return "Čeština"
        }
    }
}

enum VoiceFrequency: String, Codable, CaseIterable, Identifiable {
    case low, normal, high
    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: return T("Minimal")
        case .normal: return T("Normal")
        case .high: return T("Detailed")
        }
    }
}

enum AudioOutput: String, Codable, CaseIterable, Identifiable {
    case system, bluetooth, speaker
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return T("Default")
        case .bluetooth: return "Bluetooth"
        case .speaker: return T("Phone speaker")
        }
    }
}

enum AudioMode: String, Codable, CaseIterable, Identifiable {
    case media, call
    var id: String { rawValue }
    var label: String { self == .media ? T("As media") : T("As phone call") }
}

struct VoiceSettings: Codable {
    var enabled = true
    var streetNames = true
    var volume: Double = 1.0
    var language: VoiceLanguage = .app
    var voiceId: String = ""              // prázdné = automaticky nejlepší hlas
    var rate: Double = 1.0                // násobek výchozí rychlosti řeči
    var frequency: VoiceFrequency = .normal
    var output: AudioOutput = .system
    var mode: AudioMode = .media

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoiceSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        streetNames = (try? c.decodeIfPresent(Bool.self, forKey: .streetNames)) ?? d.streetNames
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? d.volume
        language = (try? c.decodeIfPresent(VoiceLanguage.self, forKey: .language)) ?? d.language
        voiceId = (try? c.decodeIfPresent(String.self, forKey: .voiceId)) ?? d.voiceId
        rate = (try? c.decodeIfPresent(Double.self, forKey: .rate)) ?? d.rate
        frequency = (try? c.decodeIfPresent(VoiceFrequency.self, forKey: .frequency)) ?? d.frequency
        output = (try? c.decodeIfPresent(AudioOutput.self, forKey: .output)) ?? d.output
        mode = (try? c.decodeIfPresent(AudioMode.self, forKey: .mode)) ?? d.mode
    }

    /// Skutečný jazyk pokynů.
    var effectiveLanguage: AppLanguage {
        switch language {
        case .app: return L10n.lang
        case .en: return .en
        case .cs: return .cs
        }
    }
}

/// Hlasové pokyny přes vestavěný převod textu na řeč iPhonu (funguje na pozadí, jde do helmy přes intercom).
/// Volá se z hlavního vlákna při každé nové poloze.
final class VoiceGuide: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var settings = VoiceSettings()

    private var maneuverKey = ""
    private var spokenLevel = 0          // kolik upozornění u tohoto manévru už zaznělo (0 = žádné)
    private var lastSpoke = Date.distantPast
    private var arrivedSpoken = false
    private var routeGen = -1
    private var mentionedNextKey = ""     // manévr ohlášený přes „poté …“
    private var releaseAttempt = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Hlasy nainstalované v iPhonu pro daný jazyk (nejkvalitnější první).
    static func voices(for lang: AppLanguage) -> [AVSpeechSynthesisVoice] {
        let prefix = String(lang.speechCode.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    static func describe(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium: q = T("premium")
        case .enhanced: q = T("enhanced")
        default: q = T("standard")
        }
        return "\(v.name) (\(v.language), \(q))"
    }

    // MARK: Veřejné
    func reset() {
        maneuverKey = ""
        spokenLevel = 0
        arrivedSpoken = false
        routeGen = -1
        mentionedNextKey = ""
        synth.stopSpeaking(at: .immediate)
    }

    /// Nová trasa / přepočet.
    func routeStarted(generation: Int, reroute: Bool) {
        guard generation != routeGen else { return }
        routeGen = generation
        maneuverKey = ""
        spokenLevel = 0
        arrivedSpoken = false
        mentionedNextKey = ""
        if reroute { say(cs ? "Přepočítávám trasu." : "Recalculating.") }
    }

    func update(_ s: NavSnapshot, speed: Double) {
        guard settings.enabled, s.guiding else { return }
        if s.arrived {
            if !arrivedSpoken { arrivedSpoken = true; say(arrivalNow(s.icon)) }
            return
        }
        let key = "\(s.maneuverIndex)|\(s.icon)|\(s.road)"
        if key != maneuverKey { maneuverKey = key; spokenLevel = 0 }

        // Hranice vzdáleností podle rychlosti (m/s; ve stoje počítáme ~30 km/h)
        let v = max(8.0, speed)
        let nowD = max(30.0, v * 3.5)
        let nearD = min(400.0, max(70.0, v * 8))
        let midD = min(900.0, max(200.0, v * 16))
        let farD = min(2000.0, max(400.0, v * 35))
        // Úrovně podle četnosti (od nejvzdálenější); „nyní“ je vždy poslední
        let tiers: [Double]
        switch settings.frequency {
        case .low: tiers = [nearD]
        case .normal: tiers = [midD, nearD]
        case .high: tiers = [farD, midD, nearD]
        }
        let d = s.toNext

        if d <= nowD {
            if spokenLevel <= tiers.count {
                spokenLevel = tiers.count + 1
                say(instruction(s, distance: nil))
            }
            return
        }
        // Pokud byl tento manévr už ohlášen přes „poté …“ a je blízko, počkáme až na „nyní“
        if !mentionedNextKey.isEmpty && key.hasPrefix(mentionedNextKey) && d < nearD * 1.5 { return }
        // Nejbližší úroveň, do které jsme se dostali a která ještě nezazněla
        var reached = 0
        for (i, t) in tiers.enumerated() where d <= t { reached = i + 1 }
        guard reached > spokenLevel else { return }
        // Nehlásit těsně po předchozím pokynu (kromě „nyní“)
        if Date().timeIntervalSince(lastSpoke) < 6 { return }
        // Nehlásit „za 50 m“, když je to skoro „nyní“ – radši počkat
        if d < nowD * 1.6 { return }
        spokenLevel = reached
        say(instruction(s, distance: d))
    }

    func sample() {
        var s = NavSnapshot()
        s.icon = TurnIcon.turnL
        s.street = cs ? "Třída Tomáše Bati" : "Main Street"
        s.road = s.street
        say(instruction(s, distance: 300))
    }

    // MARK: Zvuk
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            switch (settings.output, settings.mode) {
            case (.speaker, _):
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
                try session.setActive(true)
                try session.overrideOutputAudioPort(.speaker)
            case (_, .call):
                // „Jako hovor“: Bluetooth HFP (intercomy), bez Bluetooth reproduktor
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker, .duckOthers])
                try session.setActive(true)
            default:
                // „Jako média“: A2DP do helmy, jinak reproduktor; hudba se jen ztiší
                try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
                try session.setActive(true)
            }
        } catch {
            log("⚠️ Zvuk: \(error.localizedDescription)")
        }
    }

    private func say(_ text: String) {
        guard !text.isEmpty else { return }
        configureSession()
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let u = AVSpeechUtterance(string: text)
        u.voice = chosenVoice()
        u.volume = Float(min(1, max(0.1, settings.volume)))
        let r = AVSpeechUtteranceDefaultSpeechRate * Float(min(1.6, max(0.6, settings.rate)))
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, r))
        synth.speak(u)
        lastSpoke = Date()
        releaseAttempt = 0
        log("🔊 \(text)")
    }

    private func chosenVoice() -> AVSpeechSynthesisVoice? {
        if !settings.voiceId.isEmpty, let v = AVSpeechSynthesisVoice(identifier: settings.voiceId),
           v.language.hasPrefix(String(settings.effectiveLanguage.speechCode.prefix(2))) {
            return v
        }
        return VoiceGuide.voices(for: settings.effectiveLanguage).first
            ?? AVSpeechSynthesisVoice(language: settings.effectiveLanguage.speechCode)
    }

    /// Uvolní zvuk, aby se hudba vrátila na původní hlasitost. iOS to odmítne, dokud syntéza ještě
    /// dobíhá – proto s malým zpožděním a opakovaně.
    private func releaseAudio() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, !self.synth.isSpeaking else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                self.releaseAttempt += 1
                if self.releaseAttempt <= 5 { self.releaseAudio() }
                else { log("⚠️ Zvuk se nepodařilo uvolnit: \(error.localizedDescription)") }
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        releaseAudio()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        releaseAudio()
    }

    // MARK: Skládání vět
    private var cs: Bool { settings.effectiveLanguage == .cs }

    /// „Za 300 metrů odbočte vlevo na X.“ / „Nyní odbočte vlevo na X.“
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
            mentionedNextKey = "\(s.maneuverIndex + 1)|\(n)|"
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

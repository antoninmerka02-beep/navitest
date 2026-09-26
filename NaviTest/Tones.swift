import Foundation

/// Zvuk upozornění: hlas (převod textu na řeč) nebo jeden z 10 generovaných tónů.
enum AlertSound: String, Codable, CaseIterable, Identifiable {
    case voice, beep, doubleBeep, tripleBeep, gong, laser, radar, chime, siren, warning, soft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .voice: return T("Voice")
        case .beep: return T("Beep")
        case .doubleBeep: return T("Double beep")
        case .tripleBeep: return T("Triple beep")
        case .gong: return T("Gong")
        case .laser: return T("Laser")
        case .radar: return T("Radar pulses")
        case .chime: return T("Chime")
        case .siren: return T("Siren")
        case .warning: return T("Warning buzz")
        case .soft: return T("Soft melody")
        }
    }
}

/// Generuje tóny jako WAV (16 bit, mono, 22 050 Hz) – přehrají se přes AVAudioPlayer.
enum ToneGenerator {
    static let rate = 22_050.0

    private struct Part {
        var f0: Double          // počáteční frekvence
        var f1: Double          // koncová frekvence (sweep)
        var dur: Double         // délka v s
        var square = false
        var decay = false       // doznívání (zvonek, gong)
        var gap = 0.0           // ticho po tónu
        var f2: Double = 0      // druhý harmonický tón (zvonek)
    }

    static func wav(_ s: AlertSound) -> Data? {
        let parts: [Part]
        switch s {
        case .voice: return nil
        case .beep: parts = [Part(f0: 1000, f1: 1000, dur: 0.18)]
        case .doubleBeep: parts = [Part(f0: 1100, f1: 1100, dur: 0.12, gap: 0.08), Part(f0: 1100, f1: 1100, dur: 0.12)]
        case .tripleBeep: parts = (0..<3).map { _ in Part(f0: 1250, f1: 1250, dur: 0.09, gap: 0.06) }
        case .gong: parts = [Part(f0: 660, f1: 660, dur: 0.45, decay: true, f2: 990), Part(f0: 523, f1: 523, dur: 0.7, decay: true, f2: 785)]
        case .laser: parts = [Part(f0: 2200, f1: 350, dur: 0.35)]
        case .radar: parts = (0..<5).map { _ in Part(f0: 1500, f1: 1500, dur: 0.05, square: true, gap: 0.05) }
        case .chime: parts = [Part(f0: 880, f1: 880, dur: 0.9, decay: true, f2: 1320)]
        case .siren: parts = [Part(f0: 600, f1: 1200, dur: 0.35), Part(f0: 1200, f1: 600, dur: 0.35),
                              Part(f0: 600, f1: 1200, dur: 0.35), Part(f0: 1200, f1: 600, dur: 0.35)]
        case .warning: parts = (0..<3).map { _ in Part(f0: 440, f1: 440, dur: 0.16, square: true, gap: 0.08) }
        case .soft: parts = [Part(f0: 523, f1: 523, dur: 0.16, decay: true), Part(f0: 659, f1: 659, dur: 0.16, decay: true),
                             Part(f0: 784, f1: 784, dur: 0.35, decay: true)]
        }
        var samples: [Int16] = []
        for p in parts {
            let n = Int(p.dur * rate)
            var phase = 0.0, phase2 = 0.0
            for i in 0..<n {
                let t = Double(i) / Double(n)
                let f = p.f0 + (p.f1 - p.f0) * t
                phase += 2 * Double.pi * f / rate
                phase2 += 2 * Double.pi * p.f2 / rate
                var v = p.square ? (sin(phase) >= 0 ? 0.6 : -0.6) : sin(phase)
                if p.f2 > 0 { v = 0.7 * v + 0.3 * sin(phase2) }
                // obálka: krátký náběh/doběh proti lupnutí, u zvonků doznívání
                let attack = min(1, Double(i) / (0.005 * rate))
                let release = min(1, Double(n - i) / (0.01 * rate))
                var env = attack * release
                if p.decay { env *= exp(-3.5 * t) }
                samples.append(Int16(max(-1, min(1, v * env * 0.8)) * 32_000))
            }
            samples += [Int16](repeating: 0, count: Int(p.gap * rate))
        }
        return makeWav(samples)
    }

    private static func makeWav(_ s: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataBytes = UInt32(s.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        for v in s { u16(UInt16(bitPattern: v)) }
        return d
    }
}

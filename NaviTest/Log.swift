import Foundation

/// Log: posledních 400 řádků vždy v paměti (pro obrazovku „Otevřít log“),
/// do souboru jen když je zapnuté „Ukládat log“ (výchozí vypnuto).
final class Log: ObservableObject {
    static let shared = Log()
    static let enabledKey = "log.enabled"

    @Published private(set) var lines: [String] = []
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Log.enabledKey)
            if enabled { add("📝 Ukládání logu zapnuto") } else { DispatchQueue.main.async { self.lines.removeAll() } }
        }
    }
    let fileURL: URL
    private let queue = DispatchQueue(label: "navitest.log")
    private let timeFmt: DateFormatter
    private var fileCreated = false

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Log.enabledKey)   // výchozí false
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        fileURL = docs.appendingPathComponent("navitest_\(f.string(from: Date())).txt")
        timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss.SSS"
    }

    func add(_ s: String) {
        guard enabled else { return }        // vypnuto = nic se neukládá ani nedrží v paměti
        let url = fileURL
        let toFile = true
        queue.async {
            let line = "\(self.timeFmt.string(from: Date()))  \(s)"
            if toFile {
                if !self.fileCreated {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    self.fileCreated = true
                }
                if let h = try? FileHandle(forWritingTo: url), let d = (line + "\n").data(using: .utf8) {
                    h.seekToEndOfFile()
                    h.write(d)
                    try? h.close()
                }
            }
            DispatchQueue.main.async {
                self.lines.append(line)
                if self.lines.count > 400 { self.lines.removeFirst(self.lines.count - 400) }
            }
        }
    }

    /// Text k exportu: celý soubor (když se ukládá), jinak řádky z paměti.
    func exportText() -> String {
        if enabled, let s = try? String(contentsOf: fileURL, encoding: .utf8), !s.isEmpty { return s }
        return lines.joined(separator: "\n")
    }
}

func log(_ s: String) { Log.shared.add(s) }

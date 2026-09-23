import Foundation

/// Log na obrazovku + do souboru v Dokumentech (viditelné v appce Soubory → Na iPhonu → NaviTest).
final class Log: ObservableObject {
    static let shared = Log()

    @Published private(set) var lines: [String] = []
    let fileURL: URL
    private let queue = DispatchQueue(label: "navitest.log")
    private let timeFmt: DateFormatter

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        fileURL = docs.appendingPathComponent("navitest_\(f.string(from: Date())).txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss.SSS"
    }

    func add(_ s: String) {
        let url = fileURL
        queue.async {
            let line = "\(self.timeFmt.string(from: Date()))  \(s)"
            if let h = try? FileHandle(forWritingTo: url), let d = (line + "\n").data(using: .utf8) {
                h.seekToEndOfFile()
                h.write(d)
                try? h.close()
            }
            DispatchQueue.main.async {
                self.lines.append(line)
                if self.lines.count > 400 { self.lines.removeFirst(self.lines.count - 400) }
            }
        }
    }
}

func log(_ s: String) { Log.shared.add(s) }

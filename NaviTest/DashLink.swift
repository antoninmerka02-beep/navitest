import Foundation
import ExternalAccessory

/// Spojení s přístrojovkou: MFi External Accessory „Communication Control Unit“ (Yamaha),
/// protokol com.garmin.navilite.data. Vlastní vlákno s RunLoopem obsluhuje streamy.
final class DashLink: NSObject, StreamDelegate {
    static let proto = "com.garmin.navilite.data"

    private var session: EASession?
    private var generation = 0
    private var inp: InputStream?
    private var out: OutputStream?
    private var thread: Thread?

    private let cond = NSCondition()
    private var rx: [UInt8] = []
    private let txLock = NSLock()
    private var tx: [UInt8] = []

    private let stateLock = NSLock()
    private var _open = false
    var isOpen: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _open
    }
    private func setOpen(_ v: Bool) { stateLock.lock(); _open = v; stateLock.unlock() }

    var pendingTx: Int { txLock.lock(); defer { txLock.unlock() }; return tx.count }

    // MARK: Hledání příslušenství
    static func describe(_ a: EAAccessory) -> String {
        "\(a.name) | výrobce: \(a.manufacturer) | model: \(a.modelNumber) | FW: \(a.firmwareRevision) | HW: \(a.hardwareRevision) | protokoly: [\(a.protocolStrings.joined(separator: ", "))]"
    }

    static func findAccessory() -> EAAccessory? {
        EAAccessoryManager.shared().connectedAccessories.first { $0.protocolStrings.contains(proto) }
    }

    // MARK: Otevření / zavření
    func open(_ acc: EAAccessory) throws {
        close()
        guard let s = EASession(accessory: acc, forProtocol: Self.proto) else {
            throw NSError(domain: "DashLink", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "EASession se nepodařilo vytvořit (jiná appka drží spojení? zavři StreetCross/Pillion)"])
        }
        cond.lock(); rx.removeAll(); cond.unlock()
        txLock.lock(); tx.removeAll(); txLock.unlock()
        generation += 1
        let myGen = generation
        session = s
        guard let i = s.inputStream, let o = s.outputStream else {
            throw NSError(domain: "DashLink", code: 2, userInfo: [NSLocalizedDescriptionKey: "EASession nemá streamy"])
        }
        inp = i
        out = o
        setOpen(true)

        let t = Thread { [weak self] in
            guard let self = self else { return }
            i.delegate = self
            o.delegate = self
            i.schedule(in: .current, forMode: .default)
            o.schedule(in: .current, forMode: .default)
            i.open()
            o.open()
            while self.isOpen && self.generation == myGen {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
            }
            i.close(); o.close()
            i.remove(from: .current, forMode: .default)
            o.remove(from: .current, forMode: .default)
            if self.generation == myGen { self.session = nil }
            log("EA vlákno ukončeno")
        }
        t.name = "ea-io"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func close() {
        guard isOpen else { return }
        setOpen(false)
        cond.lock(); cond.broadcast(); cond.unlock()
    }

    // MARK: StreamDelegate
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        // Události ze streamů starší (už zavřené) session ignoruj.
        guard aStream === inp || aStream === out else { return }
        switch eventCode {
        case .hasBytesAvailable:
            guard let i = aStream as? InputStream else { return }
            var buf = [UInt8](repeating: 0, count: 16384)
            while i.hasBytesAvailable {
                let n = i.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                cond.lock(); rx.append(contentsOf: buf[0..<n]); cond.signal(); cond.unlock()
            }
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred:
            log("❌ Chyba streamu: \(aStream.streamError?.localizedDescription ?? "?")")
            close()
        case .endEncountered:
            log("Stream ukončen (motorka odpojena?)")
            close()
        default:
            break
        }
    }

    // MARK: Zápis
    func write(_ bytes: [UInt8]) {
        guard isOpen else { return }
        txLock.lock(); tx.append(contentsOf: bytes); txLock.unlock()
        if let t = thread, !t.isFinished {
            perform(#selector(flush), on: t, with: nil, waitUntilDone: false)
        }
    }

    @objc private func flush() {
        guard let o = out, o.streamStatus == .open else { return }
        txLock.lock(); defer { txLock.unlock() }
        while !tx.isEmpty && o.hasSpaceAvailable {
            let n = tx.withUnsafeBufferPointer { p -> Int in
                guard let base = p.baseAddress else { return 0 }
                return o.write(base, maxLength: p.count)
            }
            if n <= 0 { break }
            tx.removeFirst(n)
        }
    }

    // MARK: Čtení rámců
    /// Vrátí další celý rámec, nebo nil po vypršení timeoutu / zavření spojení.
    func readFrame(timeout: TimeInterval) -> InFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while true {
            if let f = parseLocked() { return f }
            if !isOpen { return nil }
            if !cond.wait(until: deadline) { return parseLocked() }
        }
    }

    /// Volat se zamčeným `cond`.
    private func parseLocked() -> InFrame? {
        while true {
            // Resynchronizace na magic "nAl@"
            var drop = 0
            while rx.count - drop >= 4 &&
                    !(rx[drop] == 0x6E && rx[drop + 1] == 0x41 && rx[drop + 2] == 0x6C && rx[drop + 3] == 0x40) {
                drop += 1
            }
            if drop > 0 { rx.removeFirst(drop) }
            guard rx.count >= 16 else { return nil }
            let size = Int(rx[7]) | (Int(rx[8]) << 8) | (Int(rx[9]) << 16) | (Int(rx[10]) << 24)
            if size > 2_000_000 { rx.removeFirst(); continue } // nesmysl → hledej dál
            guard rx.count >= 16 + size else { return nil }
            let f = InFrame(frameType: rx[5], svc: rx[6], pdt: rx[11], payload: Array(rx[16..<(16 + size)]))
            rx.removeFirst(16 + size)
            return f
        }
    }
}

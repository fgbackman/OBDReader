import Foundation

// MARK: - Record & replay
//
// Recording saves every command the app sent and the adapter's exact reply. Replaying feeds those
// replies back through the same code path, so a session captured on a real car (say, in
// California) can be opened on another Mac (say, in the UK) and every page works as if the car
// were there. Useful for developing against real data and for sharing a problem with a mechanic.

struct Exchange: Codable {
    let t: Double          // seconds since recording started
    let cmd: String
    let reply: String      // raw text up to the '>' prompt, or "<TIMEOUT>"
}

struct Recording: Codable {
    var created = Date()
    var adapter = ""
    var note = ""
    var exchanges: [Exchange] = []

    static let fileExtension = "obdrec"

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("OBDReader/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func save() throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = Self.folder.appendingPathComponent("\(f.string(from: created)).\(Self.fileExtension)")
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        try e.encode(self).write(to: url, options: .atomic)
        return url
    }

    static func load(_ url: URL) throws -> Recording {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Recording.self, from: Data(contentsOf: url))
    }
}

/// Wraps a real transport and keeps a copy of everything that goes through it.
final class RecordingTransport: Transport {
    let inner: Transport
    private let lock = NSLock()
    private var exchanges: [Exchange] = []
    private let start = Date()

    init(_ inner: Transport) { self.inner = inner }

    var name: String { inner.name + " (recording)" }
    func open() throws { try inner.open() }
    func close() { inner.close() }

    func send(_ command: String, timeout: TimeInterval) throws -> String {
        let t = Date().timeIntervalSince(start)
        do {
            let reply = try inner.send(command, timeout: timeout)
            add(Exchange(t: t, cmd: command, reply: reply))
            return reply
        } catch TransportError.timeout(let c) {
            add(Exchange(t: t, cmd: command, reply: "<TIMEOUT>"))
            throw TransportError.timeout(c)
        }
    }

    /// Bus listening passes straight through; it isn't part of a replayable recording.
    func monitor(_ command: String, seconds: TimeInterval) throws -> String {
        try inner.monitor(command, seconds: seconds)
    }

    private func add(_ e: Exchange) { lock.lock(); exchanges.append(e); lock.unlock() }

    var count: Int { lock.lock(); defer { lock.unlock() }; return exchanges.count }

    func recording(adapter: String) -> Recording {
        lock.lock(); defer { lock.unlock() }
        return Recording(created: start, adapter: adapter, exchanges: exchanges)
    }
}

/// Plays a recording back. Commands seen in the recording get their recorded replies in order
/// (cycling, so live data keeps moving). Live-data requests for a different mix of sensors than
/// was recorded are rebuilt from the per-sensor values captured during the session.
final class ReplayTransport: Transport {
    let recording: Recording
    let fileName: String
    private let lock = NSLock()
    private var replies: [String: [String]] = [:]
    private var cursor: [String: Int] = [:]
    private var pidSamples: [UInt8: [[UInt8]]] = [:]
    private var pidCursor: [UInt8: Int] = [:]
    private var header = "7E8"
    private var is29Bit = false
    private var isOpen = false

    init(_ recording: Recording, fileName: String) {
        self.recording = recording
        self.fileName = fileName
        for e in recording.exchanges {
            replies[Self.key(e.cmd), default: []].append(e.reply)
        }
        indexLiveData()
    }

    var name: String { "Replay: \(fileName)" }
    func open() throws { isOpen = true }
    func close() { isOpen = false }

    private static func key(_ cmd: String) -> String {
        cmd.uppercased().replacingOccurrences(of: " ", with: "")
    }

    /// Pull every Mode 01 value out of the recorded replies, per PID, in time order.
    private func indexLiveData() {
        for e in recording.exchanges where Self.key(e.cmd).hasPrefix("01") && e.reply != "<TIMEOUT>" {
            let lines = ELM327.cleanLines(e.reply)
            guard let first = lines.first(where: { isHex($0) && $0.count > 8 }) else { continue }
            let wide = first.hasPrefix("18DA")
            guard first.count % 2 == 1 || wide else { continue }        // CAN replies only
            for m in ELM327.enginePreferred(ELM327.parseCANLines(lines, is29Bit: wide)) {
                let parsed = ELM327.parseMultiPID(m.firstFrame)
                guard !parsed.isEmpty else { continue }
                if m.ecu == "7E8" || m.ecu == "10" || pidSamples.isEmpty {
                    is29Bit = wide
                    header = wide ? "18DAF1" + m.ecu : m.ecu
                }
                for (pid, data) in parsed where pid % 0x20 != 0 && pid != 0x01 {
                    pidSamples[pid, default: []].append(data)
                }
                break
            }
        }
    }

    func send(_ command: String, timeout: TimeInterval) throws -> String {
        guard isOpen else { throw TransportError.notOpen }
        Thread.sleep(forTimeInterval: 0.01)
        let k = Self.key(command)
        lock.lock(); defer { lock.unlock() }

        if let list = replies[k], !list.isEmpty {
            let i = cursor[k, default: 0]
            cursor[k] = (i + 1) % list.count
            let r = list[i]
            if r == "<TIMEOUT>" { throw TransportError.timeout(command) }
            return r
        }
        if k.hasPrefix("AT") || k.hasPrefix("ST") { return "OK\r\r>" }
        if k.hasPrefix("01"), k.count >= 4, let out = synthesize(k) { return out }
        return "NO DATA\r\r>"
    }

    /// Build a Mode 01 reply for any combination of recorded PIDs.
    private func synthesize(_ k: String) -> String? {
        var hex = String(k.dropFirst(2))
        if hex.count % 2 == 1 { hex.removeLast() }       // "010C1" response-count suffix
        var payload: [UInt8] = [0x41]
        for pid in hexBytes(hex) {
            guard let samples = pidSamples[pid], !samples.isEmpty else { continue }
            let i = pidCursor[pid, default: 0]
            pidCursor[pid] = (i + 1) % samples.count
            payload += [pid] + samples[i]
        }
        guard payload.count > 1 else { return nil }
        return ISOTP.lines(header: header, payload: payload).joined(separator: "\r") + "\r\r>"
    }
}

enum ISOTP {
    /// Print a payload as ISO-TP frames the way an ELM327 shows them (headers on, no spaces).
    static func lines(header: String, payload: [UInt8]) -> [String] {
        func line(_ bytes: [UInt8]) -> String {
            let padded = bytes + Array(repeating: 0x55, count: max(0, 8 - bytes.count))
            return header + padded.map { String(format: "%02X", $0) }.joined()
        }
        if payload.count <= 7 { return [line([UInt8(payload.count)] + payload)] }
        var out = [line([0x10 | UInt8((payload.count >> 8) & 0x0F), UInt8(payload.count & 0xFF)] + payload.prefix(6))]
        var rest = Array(payload.dropFirst(6))
        var seq: UInt8 = 1
        while !rest.isEmpty {
            out.append(line([0x20 | seq] + rest.prefix(7)))
            rest = Array(rest.dropFirst(7))
            seq = (seq + 1) & 0x0F
        }
        return out
    }
}

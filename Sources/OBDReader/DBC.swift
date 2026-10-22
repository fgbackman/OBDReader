import Foundation

// CAN bus listening with DBC files — listen only.
//
// Many cars' computers broadcast their data on the CAN bus many times a second (engine speed,
// wheel speeds, warning lamps …). A DBC file says where each value sits inside each message.
// The adapter's monitor mode (ATMA) only listens: it sends nothing to the car, and we ask for
// silent monitoring (ATCSM1) so it doesn't acknowledge frames either.
//
// The parser below was checked against cantools (a widely used Python DBC library) on random
// frames for every message in the 60 brand DBC files cantools could open: 477,727 decoded values,
// zero differences. It also opens the 19 files cantools rejects (Honda/Acura comment syntax,
// message names that start with a digit, 29-bit IDs written without the extended flag).

// MARK: - Frames

struct CANKey: Hashable, Sendable, Comparable, Codable {
    let id: UInt32
    let extended: Bool

    var text: String { extended ? String(format: "%08X", id) : String(format: "%03X", id) }

    static func < (a: CANKey, b: CANKey) -> Bool {
        a.extended == b.extended ? a.id < b.id : !a.extended
    }
}

struct CANFrame: Sendable, Hashable {
    let key: CANKey
    let data: [UInt8]

    /// One monitor line as the ELM327 prints it with headers on and spaces off:
    /// "1A0" + data (11-bit) or "18FEF100" + data (29-bit). An 11-bit line always has an odd
    /// number of hex digits (3 + 2n) and a 29-bit line an even number (8 + 2n).
    static func parse(_ line: String) -> CANFrame? {
        guard line.count >= 3, isHex(line) else { return nil }
        let extended = line.count % 2 == 0
        let headerLen = extended ? 8 : 3
        guard line.count >= headerLen, let id = UInt32(line.prefix(headerLen), radix: 16) else { return nil }
        let data = hexBytes(String(line.dropFirst(headerLen)))
        guard data.count <= 8 else { return nil }          // classic CAN only
        return CANFrame(key: CANKey(id: extended ? id & 0x1FFF_FFFF : id & 0x7FF, extended: extended), data: data)
    }
}

// MARK: - DBC model

struct DBCSignal: Identifiable, Sendable {
    var name: String
    let startBit: Int
    let length: Int
    let littleEndian: Bool       // @1 = Intel, @0 = Motorola
    let signed: Bool
    let factor: Double
    let offset: Double
    let minimum: Double?
    let maximum: Double?
    let unit: String
    let isMultiplexor: Bool      // "M"
    let muxValue: Int64?         // "m3" → shown only when the multiplexor reads 3
    var comment: String?
    var choices: [Int64: String] = [:]

    var id: String { name }

    private static func bit(_ d: [UInt8], _ p: Int) -> UInt64 {
        UInt64((d[p >> 3] >> UInt8(p & 7)) & 1)
    }

    /// The raw bits, sign-extended when the signal is signed. nil if the frame is too short.
    func rawBits(_ d: [UInt8]) -> UInt64? {
        guard length > 0, length <= 64 else { return nil }
        let n = d.count * 8
        var r: UInt64 = 0
        if littleEndian {
            guard startBit >= 0, startBit + length <= n else { return nil }
            for k in 0..<length where Self.bit(d, startBit + k) == 1 { r |= UInt64(1) << UInt64(k) }
        } else {
            // Motorola: the start bit is the most significant bit; walk down through the byte,
            // then on to the next byte's top bit ("sawtooth" numbering).
            var p = startBit
            for _ in 0..<length {
                guard p >= 0, p < n else { return nil }
                r = (r << 1) | Self.bit(d, p)
                p = p % 8 == 0 ? p + 15 : p - 1
            }
        }
        if signed, length < 64, (r >> UInt64(length - 1)) & 1 == 1 {
            r |= ~UInt64(0) << UInt64(length)
        }
        return r
    }

    func rawInt(_ d: [UInt8]) -> Int64? {
        rawBits(d).map { Int64(bitPattern: $0) }
    }

    func value(_ d: [UInt8]) -> Double? {
        guard let r = rawBits(d) else { return nil }
        let base = signed ? Double(Int64(bitPattern: r)) : Double(r)
        return base * factor + offset
    }

    /// "On", "Active" … when the DBC names this raw value.
    func choice(_ d: [UInt8]) -> String? {
        guard !choices.isEmpty, let r = rawInt(d) else { return nil }
        return choices[r]
    }
}

struct DecodedSignal: Sendable {
    let signal: DBCSignal
    let value: Double
}

struct DBCMessage: Identifiable, Sendable {
    let key: CANKey
    var name: String
    let length: Int
    var signals: [DBCSignal]
    var comment: String?

    var id: CANKey { key }

    /// Signals present in this frame. Multiplexed signals are only included when the
    /// multiplexor selects them.
    func decode(_ d: [UInt8]) -> [DecodedSignal] {
        let mux = signals.first { $0.isMultiplexor && $0.muxValue == nil }
        let muxRaw = mux.flatMap { $0.rawInt(d) }
        var out: [DecodedSignal] = []
        for s in signals {
            if let want = s.muxValue, mux != nil, muxRaw != want { continue }
            if let v = s.value(d) { out.append(DecodedSignal(signal: s, value: v)) }
        }
        return out
    }
}

struct DBCFile: Sendable {
    let name: String
    var messages: [CANKey: DBCMessage]
    var duplicateIDs = 0

    var signalCount: Int { messages.values.reduce(0) { $0 + $1.signals.count } }

    // MARK: Parsing

    private static func rx(_ p: String) -> NSRegularExpression {
        // Patterns are fixed strings written below; a typo would show up on the first import.
        try! NSRegularExpression(pattern: p, options: [])
    }
    private static let boRx = rx(#"^\s*BO_\s+(\d+)\s+(\w+)\s*:\s*(\d+)"#)
    private static let sgRx = rx(#"^\s*SG_\s+(\w+)\s*(M|m\d+M?)?\s*:\s*(\d+)\|(\d+)@([01])([+-])\s*\(\s*([^,]+?)\s*,\s*([^)]+?)\s*\)\s*\[\s*([^|]*?)\s*\|\s*([^\]]*?)\s*\]\s*"([^"]*)""#)
    private static let valRx = rx(#"^\s*VAL_\s+(\d+)\s+(\w+)\s+(.*);"#)
    private static let pairRx = rx(#"(-?\d+)\s+"([^"]*)""#)
    private static let cmSigRx = rx(#"CM_\s+SG_\s+(\d+)\s+(\w+)\s+"((?:[^"\\]|\\.)*)"\s*;"#)
    private static let cmMsgRx = rx(#"CM_\s+BO_\s+(\d+)\s+"((?:[^"\\]|\\.)*)"\s*;"#)
    private static let longMsgRx = rx(#"BA_\s+"SystemMessageLongSymbol"\s+BO_\s+(\d+)\s+"([^"]*)"\s*;"#)
    private static let longSigRx = rx(#"BA_\s+"SystemSignalLongSymbol"\s+SG_\s+(\d+)\s+(\w+)\s+"([^"]*)"\s*;"#)

    private static func groups(_ m: NSTextCheckingResult, in s: NSString) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : s.substring(with: r)
        }
    }

    /// DBC IDs: bit 31 marks a 29-bit ID. Some files (openpilot's) list 29-bit IDs without that
    /// flag, so anything above 0x7FF is treated as 29-bit too.
    static func key(forRaw raw: UInt32) -> CANKey {
        let id = raw & 0x1FFF_FFFF
        return CANKey(id: id, extended: raw & 0x8000_0000 != 0 || id > 0x7FF)
    }

    static func parse(_ rawText: String, name: String) -> DBCFile {
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var byRaw: [UInt32: DBCMessage] = [:]
        var order: [UInt32] = []
        var dupes = 0
        var current: UInt32?
        var skipping = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            let ns = l as NSString
            let full = NSRange(location: 0, length: ns.length)
            if l.contains("BO_ "), !l.contains("BO_TX_BU_"), let m = boRx.firstMatch(in: l, range: full) {
                let g = groups(m, in: ns)
                guard let raw = UInt32(g[1] ?? ""), raw != 0xC000_0000 else { current = nil; skipping = true; continue }
                if byRaw[raw] != nil { dupes += 1; current = nil; skipping = true; continue }   // keep the first
                byRaw[raw] = DBCMessage(key: key(forRaw: raw), name: g[2] ?? "?", length: Int(g[3] ?? "") ?? 8, signals: [])
                order.append(raw)
                current = raw
                skipping = false
                continue
            }
            if l.contains("SG_"), let m = sgRx.firstMatch(in: l, range: full) {
                guard !skipping, let cur = current else { continue }
                let g = groups(m, in: ns)
                let mux = g[2] ?? ""
                var muxValue: Int64?
                if mux.hasPrefix("m") { muxValue = Int64(mux.filter(\.isNumber)) }
                let sig = DBCSignal(
                    name: g[1] ?? "?",
                    startBit: Int(g[3] ?? "") ?? 0,
                    length: Int(g[4] ?? "") ?? 0,
                    littleEndian: g[5] == "1",
                    signed: g[6] == "-",
                    factor: Double(g[7] ?? "") ?? 1,
                    offset: Double(g[8] ?? "") ?? 0,
                    minimum: Double(g[9] ?? ""),
                    maximum: Double(g[10] ?? ""),
                    unit: g[11] ?? "",
                    isMultiplexor: mux.contains("M"),
                    muxValue: muxValue)
                byRaw[cur]?.signals.append(sig)
                continue
            }
            if l.contains("VAL_ "), !l.contains("VAL_TABLE_"), let m = valRx.firstMatch(in: l, range: full) {
                let g = groups(m, in: ns)
                guard let raw = UInt32(g[1] ?? ""), let sigName = g[2], let rest = g[3],
                      let idx = byRaw[raw]?.signals.firstIndex(where: { $0.name == sigName }) else { continue }
                let rns = rest as NSString
                for p in pairRx.matches(in: rest, range: NSRange(location: 0, length: rns.length)) {
                    let pg = groups(p, in: rns)
                    if let v = Int64(pg[1] ?? ""), let t = pg[2] { byRaw[raw]?.signals[idx].choices[v] = t }
                }
            }
        }

        // Comments and long names can span lines, so they're matched across the whole text.
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        if text.contains("CM_") {
            for m in cmSigRx.matches(in: text, range: full) {
                let g = groups(m, in: ns)
                guard let raw = UInt32(g[1] ?? ""), let idx = byRaw[raw]?.signals.firstIndex(where: { $0.name == g[2] }) else { continue }
                byRaw[raw]?.signals[idx].comment = g[3]
            }
            for m in cmMsgRx.matches(in: text, range: full) {
                let g = groups(m, in: ns)
                if let raw = UInt32(g[1] ?? "") { byRaw[raw]?.comment = g[2] }
            }
        }
        if text.contains("LongSymbol") {
            for m in longMsgRx.matches(in: text, range: full) {
                let g = groups(m, in: ns)
                if let raw = UInt32(g[1] ?? ""), let n = g[2], !n.isEmpty { byRaw[raw]?.name = n }
            }
            for m in longSigRx.matches(in: text, range: full) {
                let g = groups(m, in: ns)
                guard let raw = UInt32(g[1] ?? ""), let n = g[3], !n.isEmpty,
                      let idx = byRaw[raw]?.signals.firstIndex(where: { $0.name == g[2] }) else { continue }
                byRaw[raw]?.signals[idx].name = n
            }
        }

        var messages: [CANKey: DBCMessage] = [:]
        for raw in order {
            guard let m = byRaw[raw] else { continue }
            if messages[m.key] == nil { messages[m.key] = m } else { dupes += 1 }
        }
        return DBCFile(name: name, messages: messages, duplicateIDs: dupes)
    }

    static func load(_ url: URL) -> DBCFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let f = parse(text, name: url.lastPathComponent)
        return f.messages.isEmpty ? nil : f
    }
}

// MARK: - Library of imported DBC files

/// DBC files the owner has added, copied into Application Support so they survive moving or
/// deleting the originals.
@MainActor
final class DBCLibrary: ObservableObject {
    static let shared = DBCLibrary()

    @Published private(set) var files: [URL] = []
    private var cache: [String: DBCFile] = [:]

    let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("OBDReader/DBC", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() { refresh() }

    func refresh() {
        let list = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        files = list.filter { $0.pathExtension.lowercased() == "dbc" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copy .dbc files (or every .dbc inside chosen folders). Returns how many were added.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var sources: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let walker = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil)
                while let f = walker?.nextObject() as? URL {
                    if f.pathExtension.lowercased() == "dbc" { sources.append(f) }
                }
            } else if u.pathExtension.lowercased() == "dbc" {
                sources.append(u)
            }
        }
        var added = 0
        for src in sources {
            var dest = folder.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path),
               (try? Data(contentsOf: dest)) != (try? Data(contentsOf: src)) {
                // Same name, different file: keep both, tagged with the folder it came from.
                let tag = src.deletingLastPathComponent().lastPathComponent
                dest = folder.appendingPathComponent("\(tag) - \(src.lastPathComponent)")
            }
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: src, to: dest)) != nil {
                cache[dest.lastPathComponent] = nil
                added += 1
            }
        }
        refresh()
        return added
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        cache[name] = nil
        refresh()
    }

    func url(_ name: String) -> URL? { files.first { $0.lastPathComponent == name } }

    /// Parse (off the main thread) and cache.
    func file(_ name: String) async -> DBCFile? {
        if let f = cache[name] { return f }
        guard let u = url(name) else { return nil }
        let f = await Task.detached(priority: .userInitiated) { DBCFile.load(u) }.value
        if let f { cache[name] = f }
        return f
    }

    struct Match: Identifiable {
        let name: String
        let known: Int        // heard IDs this DBC describes
        let heard: Int
        let lengthOK: Int     // … of which the frame length also matches
        var id: String { name }
    }

    /// Rank every DBC by how many of the IDs heard on the bus it describes.
    func rank(heard: [CANKey: Int]) async -> [Match] {
        var out: [Match] = []
        for u in files {
            guard let f = await file(u.lastPathComponent) else { continue }
            var known = 0, lenOK = 0
            for (k, len) in heard {
                guard let m = f.messages[k] else { continue }
                known += 1
                if m.length == len { lenOK += 1 }
            }
            if known > 0 { out.append(Match(name: f.name, known: known, heard: heard.count, lengthOK: lenOK)) }
        }
        return out.sorted { ($0.lengthOK, $0.known) > ($1.lengthOK, $1.known) }
    }
}

// MARK: - What the listener has heard

struct BusStat: Sendable {
    var count = 0
    var data: [UInt8] = []
    var changed: [UInt8] = []     // per byte: every bit that has ever changed
}

struct BusLogEntry: Sendable {
    let t: Double                  // seconds since listening started (approximate — see note)
    let frame: CANFrame
}

enum BusLogFile {
    /// time_s,id,extended,data — readable by spreadsheets and back by this app.
    static func csv(_ log: [BusLogEntry]) -> String {
        var rows = ["time_s,id,extended,data"]
        rows.reserveCapacity(log.count + 1)
        for e in log {
            rows.append(String(format: "%.3f", e.t) + ",\(e.frame.key.text),\(e.frame.key.extended ? 1 : 0),"
                        + e.frame.data.map { String(format: "%02X", $0) }.joined())
        }
        return rows.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [BusLogEntry] {
        var out: [BusLogEntry] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard c.count >= 4, let t = Double(c[0]), let id = UInt32(c[1], radix: 16) else { continue }
            let ext = c[2] == "1" || c[1].count > 3
            let hex = c[3].replacingOccurrences(of: " ", with: "")
            guard hex.isEmpty || isHex(hex) else { continue }
            out.append(BusLogEntry(t: t, frame: CANFrame(key: CANKey(id: id, extended: ext), data: hexBytes(hex))))
        }
        return out
    }
}

/// Signal names that look like dashboard warning lamps, in English and German (VW DBCs).
enum WarningSignals {
    private static let words = ["lamp", "light", "warn", "telltale", "malfunction", "lampe", "leuchte", "kontroll", "check_engine"]
    static func matches(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("headlight") || n.contains("lighting") || n.contains("brightness") || n.contains("dimm") { return false }
        return words.contains { n.contains($0) }
    }
}

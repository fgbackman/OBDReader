import Foundation

/// One ECU's answer to a request. On CAN the ISO-TP frames are already reassembled into a
/// single message; on older K-line / J1850 cars each frame is kept separately.
struct ECUMessage {
    let ecu: String          // e.g. "7E8" (CAN) or "10" (K-line source address)
    let frames: [[UInt8]]    // service byte first, e.g. [0x41, 0x0C, 0x1A, 0xF8]
    let isCAN: Bool

    var firstFrame: [UInt8] { frames.first ?? [] }
}

enum ELMError: LocalizedError {
    case noData
    case unableToConnect
    case busError(String)
    case unknownCommand(String)
    case listenOnly

    var errorDescription: String? {
        switch self {
        case .noData: return "The car didn't answer that request (NO DATA)."
        case .unableToConnect: return "The adapter couldn't talk to the car. Is the ignition on?"
        case .busError(let s): return "Bus error from adapter: \(s)"
        case .unknownCommand(let c): return "The adapter didn't understand \"\(c)\"."
        case .listenOnly: return "This is a listen-only connection, so nothing is sent to the car. Disconnect and connect normally to read codes or live data."
        }
    }
}

struct OBDProtocol {
    let number: Int

    var isCAN: Bool { (6...12).contains(number) }
    var is29Bit: Bool { number == 7 || number == 9 || number == 10 }

    var description: String {
        switch number {
        case 1: return "SAE J1850 PWM (41.6 kbaud)"
        case 2: return "SAE J1850 VPW (10.4 kbaud)"
        case 3: return "ISO 9141-2 (K-line)"
        case 4: return "ISO 14230-4 KWP (5-baud init)"
        case 5: return "ISO 14230-4 KWP (fast init)"
        case 6: return "ISO 15765-4 CAN (11-bit, 500 kbaud)"
        case 7: return "ISO 15765-4 CAN (29-bit, 500 kbaud)"
        case 8: return "ISO 15765-4 CAN (11-bit, 250 kbaud)"
        case 9: return "ISO 15765-4 CAN (29-bit, 250 kbaud)"
        case 10: return "SAE J1939 CAN (29-bit, 250 kbaud)"
        case 11: return "User CAN 1 (11-bit, 125 kbaud — Ford MS-CAN)"
        case 12: return "User CAN 2 (11-bit, 50 kbaud)"
        default: return "Unknown (\(number))"
        }
    }
}

/// Driver for ELM327 / STN11xx / STN22xx adapters (OBDLink EX, SX, etc.).
/// Only standard, read-only OBD-II requests are issued, plus Mode 04 when the user
/// explicitly confirms clearing codes.
final class ELM327 {
    let transport: Transport
    private(set) var adapterID = ""
    private(set) var obdProtocol = OBDProtocol(number: 0)

    /// Called with every line sent/received, for the session log.
    var log: ((String) -> Void)?
    /// Set false during fast polling so the log isn't flooded.
    var verbose = true
    private(set) var multiPIDSupported = true
    private(set) var responseCountSupported = true

    /// ATSP value to use: "0" = automatic search, otherwise a fixed protocol ("6", "B" …).
    var protocolChoice = "0"
    /// Listen-only: only adapter commands (AT/ST) are allowed; anything that would put a
    /// message on the car's bus is refused. Used with the CAN tap.
    var listenOnly = false
    /// The car speaks OBD on UDS (SAE J1979-2): Mode 01 data is read as service 22 DIDs F4xx.
    var obdOnUDS = false

    init(transport: Transport) {
        self.transport = transport
    }

    // MARK: Setup

    func connect() throws {
        obdOnUDS = false
        try transport.open()
        _ = try? raw("ATZ", timeout: 4)            // reset (may echo garbage first)
        _ = try raw("ATE0")                        // echo off
        _ = try raw("ATL0")                        // linefeeds off
        _ = try raw("ATS0")                        // no spaces in hex
        _ = try raw("ATH1")                        // show headers so we know which ECU answered
        adapterID = (try? clean(raw("ATI"), keepSpaces: true).joined(separator: " ")) ?? "ELM327"
        if let sti = try? clean(raw("STI"), keepSpaces: true).first, !sti.contains("?") {
            adapterID = sti                        // OBDLink adapters report their STN chip here
        }
        if listenOnly {
            // The automatic search works by sending requests, so listen-only needs a fixed protocol.
            let p = protocolChoice == "0" ? "6" : protocolChoice
            _ = try raw("ATSP" + p)
            obdProtocol = OBDProtocol(number: Int(p, radix: 16) ?? 6)
            return
        }
        _ = try raw("ATSP" + protocolChoice)       // "0" = automatic protocol search
        // First real request triggers the protocol search; can take several seconds.
        do { _ = try request("0100", timeout: 12) }
        catch ELMError.noData { try connectOBDonUDS() }
        catch ELMError.unableToConnect { try connectOBDonUDS() }
        let dpn = try clean(raw("ATDPN")).first ?? "0"
        let digit = dpn.last.flatMap { Int(String($0), radix: 16) } ?? 0
        obdProtocol = OBDProtocol(number: digit)
    }

    /// Cars built for SAE J1979-2 (OBD on UDS) may not answer service 01 at all, so the
    /// automatic search finds nothing. Try the CAN protocols with the J1979-2 equivalent of
    /// 0100 (read DID F400, "supported PIDs 01–20").
    private func connectOBDonUDS() throws {
        let candidates = protocolChoice == "0" ? ["6", "7"] : [protocolChoice]
        for p in candidates {
            guard let n = Int(p, radix: 16), OBDProtocol(number: n).isCAN else { continue }
            _ = try raw("ATSP" + p)
            obdProtocol = OBDProtocol(number: n)
            if let msgs = try? request("22F400", timeout: 4),
               msgs.contains(where: { $0.firstFrame.count >= 3 && $0.firstFrame[0] == 0x62 && $0.firstFrame[1] == 0xF4 }) {
                obdOnUDS = true
                return
            }
        }
        obdProtocol = OBDProtocol(number: 0)
        throw ELMError.unableToConnect
    }

    func disconnect() {
        _ = try? raw("ATPC")                       // close protocol
        transport.close()
    }

    func batteryVoltage() -> Double? {
        guard let line = try? clean(raw("ATRV")).first else { return nil }
        return Double(line.replacingOccurrences(of: "V", with: ""))
    }

    // MARK: Requests

    /// Send an AT/ST command or OBD request and return the raw text.
    @discardableResult
    func raw(_ command: String, timeout: TimeInterval = 2) throws -> String {
        if listenOnly {
            let u = command.uppercased().replacingOccurrences(of: " ", with: "")
            let transmits = ["ATSI", "ATFI", "ATBI", "ATRTR", "STPX"].contains { u.hasPrefix($0) }
            guard (u.hasPrefix("AT") || u.hasPrefix("ST")) && !transmits else { throw ELMError.listenOnly }
        }
        if verbose { log?("→ \(command)") }
        let reply = try transport.send(command, timeout: timeout)
        if verbose {
            let shown = reply.replacingOccurrences(of: "\r", with: " ⏎ ")
                .replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            log?("← \(shown)")
        }
        return reply
    }

    /// Send an OBD request like "010C" and return one message per answering ECU.
    func request(_ command: String, timeout: TimeInterval = 3) throws -> [ECUMessage] {
        if listenOnly { throw ELMError.listenOnly }
        let (cmd, convert) = translate(command)
        let lines = clean(try raw(cmd, timeout: timeout))
        try checkErrors(lines, command: cmd)
        let proto = obdProtocol.number == 0 ? guessProtocol(lines) : obdProtocol
        let msgs = proto.isCAN ? parseCAN(lines, is29Bit: proto.is29Bit) : parseLegacy(lines)
        guard let convert else { return msgs }
        return msgs.map { ECUMessage(ecu: $0.ecu, frames: $0.frames.map(convert), isCAN: $0.isCAN) }
    }

    /// On OBD-on-UDS cars (SAE J1979-2) the Mode 01 data is read with service 22: PID xx is
    /// DID F4xx, and the VIN is DID F802. Replies are rewritten into the classic form
    /// (41 xx … / 49 02 01 …) so every existing decoder works unchanged. Byte layouts match
    /// Mode 01 (checked against the CSS Electronics OBD2 DBC v4.3).
    private func translate(_ command: String) -> (String, (([UInt8]) -> [UInt8])?) {
        guard obdOnUDS else { return (command, nil) }
        let u = command.uppercased()
        if u.hasPrefix("01"), u.count == 4 || (u.count == 5 && u.hasSuffix("1")) {
            return ("22F4" + u.dropFirst(2), { f in
                f.count >= 3 && f[0] == 0x62 && f[1] == 0xF4 ? [0x41] + Array(f[2...]) : f
            })
        }
        if u == "0902" {
            return ("22F802", { f in
                f.count >= 3 && f[0] == 0x62 && f[1] == 0xF8 && f[2] == 0x02 ? [0x49, 0x02, 0x01] + Array(f[3...]) : f
            })
        }
        return (command, nil)
    }

    // MARK: Fast live data

    /// Read several Mode 01 PIDs and return each PID's data bytes.
    /// On CAN cars up to six PIDs go in one request, which is several times faster than
    /// asking one at a time. Falls back automatically if the car or adapter doesn't support it.
    func readPIDs(_ pids: [UInt8]) -> [UInt8: [UInt8]] {
        let known = pids.filter { PIDs.def($0) != nil }
        var out: [UInt8: [UInt8]] = [:]

        if obdProtocol.isCAN && multiPIDSupported && !obdOnUDS && known.count > 1 {
            var ok = true
            for start in stride(from: 0, to: known.count, by: 6) {
                let chunk = Array(known[start..<min(start + 6, known.count)])
                let cmd = "01" + chunk.map { String(format: "%02X", Int($0)) }.joined()
                guard let msgs = try? request(cmd, timeout: 1.5),
                      case let parsed = ELM327.parseMultiPID(ELM327.enginePreferred(msgs).first?.firstFrame ?? []),
                      !parsed.isEmpty else { ok = false; break }
                out.merge(parsed) { a, _ in a }
            }
            if ok { return out }
            multiPIDSupported = false
            out = [:]
        }

        for pid in known {
            let base = String(format: "01%02X", Int(pid))
            var msgs: [ECUMessage]?
            if obdProtocol.isCAN && responseCountSupported {
                // Trailing "1" = "expect one reply", so the adapter returns without waiting out its timeout.
                do { msgs = try request(base + "1", timeout: 1.5) }
                catch ELMError.unknownCommand(_) { responseCountSupported = false; msgs = try? request(base, timeout: 1.5) }
                catch { msgs = nil }
            } else {
                msgs = try? request(base, timeout: 1.5)
            }
            guard let msgs, let def = PIDs.def(pid) else { continue }
            for m in ELM327.enginePreferred(msgs) {
                let f = m.firstFrame
                if f.count >= 2 + def.bytes, f[0] == 0x41, f[1] == pid {
                    out[pid] = Array(f[2..<(2 + def.bytes)])
                    break
                }
            }
        }
        return out
    }

    /// Engine computer first (7E8 on CAN, 10 on K-line), then everyone else.
    static func enginePreferred(_ msgs: [ECUMessage]) -> [ECUMessage] {
        func isEngine(_ m: ECUMessage) -> Bool { m.ecu == "7E8" || m.ecu == "10" }
        return msgs.filter(isEngine) + msgs.filter { !isEngine($0) }
    }

    /// [41, pidA, a…, pidB, b…] → [pidA: a…, pidB: b…]
    static func parseMultiPID(_ msg: [UInt8]) -> [UInt8: [UInt8]] {
        guard msg.first == 0x41 else { return [:] }
        var out: [UInt8: [UInt8]] = [:]
        var i = 1
        while i < msg.count, let def = PIDs.def(msg[i]), i + 1 + def.bytes <= msg.count {
            out[msg[i]] = Array(msg[(i + 1)..<(i + 1 + def.bytes)])
            i += 1 + def.bytes
        }
        return out
    }

    // MARK: Bus listening (listen only)

    /// Prepare to monitor: silent monitoring (don't acknowledge frames; ELM327 v1.4b and later —
    /// adapters without it just answer "?"), raw frames, optionally one ID only.
    func listenBegin(filter: String?) throws {
        _ = try? raw("ATCSM1")
        _ = try raw("ATCAF0")
        if let filter { _ = try raw("ATCRA" + filter) }
    }

    /// Monitor for `seconds` and return the frames heard. `overflow`: the adapter's buffer
    /// filled up (common on cheap ELM327 clones on a busy 500 kbit/s bus), so some were lost.
    func listenWindow(seconds: TimeInterval) throws -> (frames: [CANFrame], overflow: Bool) {
        let text = try transport.monitor("ATMA", seconds: seconds)
        let lines = ELM327.cleanLines(text)
        let overflow = lines.contains { $0.uppercased().contains("BUFFERFULL") }
        return (lines.compactMap(CANFrame.parse), overflow)
    }

    func listenEnd() {
        _ = try? raw("ATCRA")       // clear the ID filter
        _ = try? raw("ATAR")
        _ = try? raw("ATCAF1")
    }

    // MARK: Parsing

    func clean(_ reply: String, keepSpaces: Bool = false) -> [String] {
        ELM327.cleanLines(reply, keepSpaces: keepSpaces)
    }

    /// Split an adapter reply into trimmed lines, dropping prompts and status chatter.
    static func cleanLines(_ reply: String, keepSpaces: Bool = false) -> [String] {
        reply.replacingOccurrences(of: ">", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                return keepSpaces ? t : t.replacingOccurrences(of: " ", with: "")
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("SEARCHING") && !$0.hasPrefix("BUSINIT") }
    }

    func checkErrors(_ lines: [String], command: String) throws {
        let joined = lines.joined(separator: " ").uppercased()
        if lines.isEmpty || joined.contains("NODATA") { throw ELMError.noData }
        if joined.contains("UNABLETOCONNECT") { throw ELMError.unableToConnect }
        if joined.contains("CANERROR") || joined.contains("BUSERROR") || joined.contains("FBERROR")
            || joined.contains("DATAERROR") || joined.contains("BUFFERFULL") {
            throw ELMError.busError(joined)
        }
        if lines == ["?"] { throw ELMError.unknownCommand(command) }
    }

    /// Before ATDPN is known, infer the frame format from the first data line.
    private func guessProtocol(_ lines: [String]) -> OBDProtocol {
        guard let l = lines.first(where: { isHex($0) }) else { return OBDProtocol(number: 6) }
        if l.hasPrefix("18DA") { return OBDProtocol(number: 7) }
        if l.count % 2 == 1 { return OBDProtocol(number: 6) }   // 3-char 11-bit header
        return OBDProtocol(number: 3)
    }

    func parseCAN(_ lines: [String], is29Bit: Bool) -> [ECUMessage] {
        ELM327.parseCANLines(lines, is29Bit: is29Bit)
    }

    /// Reassemble ISO-TP frames (as printed with headers on) into one message per ECU.
    /// `extendedAddressing`: each frame starts with an address byte before the ISO-TP byte
    /// (BMW 6F1 / Toyota 750 style); it's dropped.
    static func parseCANLines(_ lines: [String], is29Bit: Bool, extendedAddressing: Bool = false) -> [ECUMessage] {
        let headerLen = is29Bit ? 8 : 3
        var order: [String] = []
        var expected: [String: Int] = [:]
        var buffers: [String: [UInt8]] = [:]

        for line in lines where isHex(line) && line.count > headerLen {
            let header = String(line.prefix(headerLen))
            let ecu = is29Bit ? String(header.suffix(2)) : header
            var bytes = hexBytes(String(line.dropFirst(headerLen)))
            if extendedAddressing { bytes = Array(bytes.dropFirst()) }
            guard let pci = bytes.first else { continue }
            if buffers[ecu] == nil { order.append(ecu); buffers[ecu] = [] }

            switch pci >> 4 {
            case 0x0:   // single frame
                let len = Int(pci & 0x0F)
                buffers[ecu] = Array(bytes.dropFirst().prefix(len))
                expected[ecu] = len
            case 0x1:   // first frame of a multi-frame message
                guard bytes.count >= 2 else { continue }
                expected[ecu] = (Int(pci & 0x0F) << 8) | Int(bytes[1])
                buffers[ecu] = Array(bytes.dropFirst(2))
            case 0x2:   // consecutive frame
                buffers[ecu, default: []].append(contentsOf: bytes.dropFirst())
            default:    // flow control or unknown – ignore
                continue
            }
        }
        return order.compactMap { ecu in
            guard var data = buffers[ecu], !data.isEmpty else { return nil }
            if let len = expected[ecu], data.count > len { data = Array(data.prefix(len)) }
            return ECUMessage(ecu: ecu, frames: [data], isCAN: true)
        }
    }

    func parseLegacy(_ lines: [String]) -> [ECUMessage] {
        var order: [String] = []
        var frames: [String: [[UInt8]]] = [:]
        for line in lines where isHex(line) {
            let bytes = hexBytes(line)
            guard bytes.count >= 5 else { continue }     // 3 header + ≥1 data + checksum
            let ecu = String(format: "%02X", bytes[2])
            if frames[ecu] == nil { order.append(ecu); frames[ecu] = [] }
            frames[ecu]!.append(Array(bytes[3..<(bytes.count - 1)]))
        }
        return order.map { ECUMessage(ecu: $0, frames: frames[$0]!, isCAN: false) }
    }
}

// MARK: - Hex helpers

func isHex(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isHexDigit }
}

func hexBytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex), i < s.endIndex {
        if let b = UInt8(s[i..<j], radix: 16) { out.append(b) }
        i = j
    }
    return out
}

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

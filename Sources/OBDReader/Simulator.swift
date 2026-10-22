import Foundation

/// Pretends to be an OBDLink adapter plugged into a W16 car, so the whole app can be tried with
/// no hardware. Replies use the same text format a real ELM327/STN chip produces (headers on,
/// spaces off, ISO-TP frames on 11-bit CAN). The car loops through a 36-second drive cycle:
/// idle, a hard launch, braking, idle — so the trip computer and performance timer have
/// something to measure.
final class SimulatedTransport: Transport {
    var name: String { "Simulator (demo car)" }
    private var isOpen = false
    private var cleared = false
    private let start = Date()
    private let lock = NSLock()
    private var crankAt: Date?
    private var header = "7DF"          // set by ATSH; module-addressed requests use it
    private var caf = true              // ATCAF0 = raw CAN frames (VW TP2.0)
    private var tpModule: UInt8?        // open TP2.0 channel
    private var tpSeq: UInt8 = 0        // module's packet counter

    static let vin = "VF9SIMULATED00001"   // obviously fake demo VIN

    /// Mode 01 PIDs engine computer A answers. The "supported" bitmaps (0100, 0120 …) are built
    /// from this list, so adding a sensor here and in liveBytes is all a new PID needs.
    static let supported: Set<UInt8> = [
        0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11,
        0x15, 0x19, 0x1F, 0x21, 0x24, 0x28, 0x2F, 0x30, 0x31, 0x33, 0x3C, 0x3D, 0x3E, 0x3F,
        0x42, 0x44, 0x46, 0x49, 0x4D, 0x4E, 0x51, 0x5C,
        0x61, 0x62, 0x63, 0x6F, 0x70, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x87, 0xA6,
    ]

    /// 4-byte "supported PIDs" bitmap for base+1 … base+0x20. The last bit means "ask about the
    /// next range too", set whenever anything higher is supported.
    private func bitmap(_ base: UInt8) -> [UInt8]? {
        var b: [UInt8] = [0, 0, 0, 0]
        var any = false
        for i in 1...32 {
            let pid = Int(base) + i
            let on = i == 32 ? Self.supported.contains { Int($0) > pid }
                             : (pid <= 0xFF && Self.supported.contains(UInt8(pid)))
            if on { b[(i - 1) / 8] |= UInt8(0x80 >> ((i - 1) % 8)); any = true }
        }
        return any ? b : nil
    }

    func open() throws { isOpen = true }
    func close() { isOpen = false }

    /// Battery test demo: engine "off" for 4 s, then it cranks and starts.
    func beginCrankScenario() {
        lock.lock(); crankAt = Date().addingTimeInterval(4); lock.unlock()
    }

    func send(_ command: String, timeout: TimeInterval) throws -> String {
        guard isOpen else { throw TransportError.notOpen }
        Thread.sleep(forTimeInterval: 0.02)   // feel like a real serial link
        let cmd = command.uppercased().replacingOccurrences(of: " ", with: "")
        return reply(to: cmd).joined(separator: "\r") + "\r\r>"
    }

    // MARK: - Bus traffic (ATMA)

    private var craFilter: String?      // ATCRA hhh

    /// The demo car broadcasts a few VW PQ-platform messages laid out as in vw_golf_mk4.dbc
    /// (Motor_1, Bremse_1, Bremse_3, Kombi_1, Kombi_2) plus one the DBC doesn't describe,
    /// so the listener has something to decode. Values follow the same drive cycle as Mode 01.
    func monitor(_ command: String, seconds: TimeInterval) throws -> String {
        guard isOpen else { throw TransportError.notOpen }
        let cmd = command.uppercased().replacingOccurrences(of: " ", with: "")
        guard cmd == "ATMA" else { return try send(command, timeout: seconds) }
        let t0 = Date().timeIntervalSince(start)
        Thread.sleep(forTimeInterval: seconds)
        lock.lock(); let filter = craFilter; lock.unlock()
        let periods: [(UInt32, Double)] = [(0x280, 0.01), (0x1A0, 0.01), (0x4A0, 0.01), (0x320, 0.02), (0x420, 0.2), (0x5D0, 0.1)]
        var lines: [String] = []
        var step = 0.0
        while step < seconds {
            for (id, period) in periods {
                let ticks = (step / period).rounded()
                guard abs(step - ticks * period) < 0.0005 else { continue }
                let head = String(format: "%03X", id)
                if let filter, filter != head { continue }
                lines.append(head + busData(id, t: t0 + step).map { String(format: "%02X", $0) }.joined())
            }
            step += 0.01
        }
        return lines.joined(separator: "\r") + "\r\rSTOPPED\r\r>"
    }

    private func busData(_ id: UInt32, t: Double) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 8)
        func put(_ start: Int, _ len: Int, _ value: Double) {          // Intel byte order
            let raw = UInt64(max(0, value.rounded())) & ((UInt64(1) << UInt64(len)) - 1)
            for k in 0..<len where (raw >> UInt64(k)) & 1 == 1 {
                d[(start + k) >> 3] |= UInt8(1 << ((start + k) & 7))
            }
        }
        let v = speedKmh(t)
        let p = t.truncatingRemainder(dividingBy: 36)
        let launching = p >= 6 && p < 18
        let rpm = v > 0 ? 1400 + v.truncatingRemainder(dividingBy: 60) / 60 * 4800 : 950 + 30 * sin(t / 2)
        let warm = min(1, t / 90)
        switch id {
        case 0x280:                                                     // Motor_1
            put(16, 16, rpm / 0.25)
            put(40, 8, (launching ? 95 : (v > 0 ? 18 : 0)) / 0.4)
        case 0x1A0:                                                     // Bremse_1
            put(17, 15, v / 0.01)
            put(8, 1, 1)                                                // Lampe_ABS — matches the ABS fault in the demo
            put(9, 1, 1)                                                // Lampe_ASR___ESP
            put(56, 4, Double(Int(t * 100) % 16))                       // counter
        case 0x4A0:                                                     // Bremse_3: VL, VR, HL, HR
            let dropout = v > 10 && Int(t * 10) % 40 < 3                // rear-left sensor cuts out now and then
            put(1, 15, v / 0.01)
            put(17, 15, v * 1.004 / 0.01)
            put(33, 15, dropout ? 0 : v * 0.998 / 0.01)
            put(49, 15, v * 1.001 / 0.01)
        case 0x320:                                                     // Kombi_1
            put(16, 7, 48)                                              // fuel, litres
            put(25, 15, v / 0.01)
            put(46, 10, v * 1.03 / 0.32)                                // displayed speed reads ~3 % high
        case 0x420:                                                     // Kombi_2
            put(8, 8, (18 + 50) / 0.5)                                  // outside temp 18 °C
            put(16, 8, (18 + 50) / 0.5)
            put(24, 8, 25 + warm * 75 + 60)                             // oil temp
            put(32, 8, (25 + warm * 65 + 48) / 0.75)                    // coolant
        default:                                                        // not in the DBC
            d = [0x12, UInt8(Int(t * 10) & 0xFF), 0, 0, 0x5A, 0, 0, 0]
        }
        return d
    }

    // MARK: - Responses

    private func reply(to cmd: String) -> [String] {
        if cmd.hasPrefix("ATCRA") {
            let f = String(cmd.dropFirst(5))
            lock.lock(); craFilter = f.isEmpty ? nil : f; lock.unlock()
            return ["OK"]
        }
        if cmd == "ATAR" { lock.lock(); craFilter = nil; lock.unlock(); return ["OK"] }
        if cmd == "ATZ" { return ["", "ELM327 v1.4b"] }
        if cmd == "ATI" { return ["ELM327 v1.4b"] }
        if cmd == "STI" { return ["STN2230 v5.10.3 (simulated)"] }
        if cmd == "ATDPN" { return ["A6"] }
        if cmd == "ATRV" { return [String(format: "%.2fV", batteryVolts())] }
        if cmd.hasPrefix("ATSH") { header = String(cmd.dropFirst(4)); return ["OK"] }
        if cmd == "ATCAF0" { caf = false; return ["OK"] }
        if cmd == "ATCAF1" { caf = true; tpModule = nil; return ["OK"] }
        if !caf && !cmd.hasPrefix("AT") { return tp20Reply(cmd) }
        if cmd.hasPrefix("AT") { return ["OK"] }
        if header != "7DF", let r = moduleReply(cmd) { return r }

        let t = Date().timeIntervalSince(start)
        switch cmd {
        case "0100":
            return frames("7E8", [0x41, 0x00] + bitmap(0x00)!)
                 + frames("7E9", [0x41, 0x00, 0x98, 0x18, 0x00, 0x00])
        case "0120", "0140", "0160", "0180", "01A0", "01C0", "01E0":
            let base = UInt8(cmd.suffix(2), radix: 16)!
            return bitmap(base).map { frames("7E8", [0x41, base] + $0) } ?? ["NO DATA"]
        case "0101":
            // 7E8 (engine A): MIL on, 2 stored codes, spark ignition; catalyst + EVAP incomplete.
            // 7E9 (engine B): supports the same monitors and reports them all complete, so the
            // merged readiness still shows engine A's catalyst as not ready.
            let a: UInt8 = cleared ? 0x00 : 0x82
            let d: UInt8 = cleared ? 0x65 : 0x05
            return frames("7E8", [0x41, 0x01, a, 0x07, 0x65, d])
                 + frames("7E9", [0x41, 0x01, 0x00, 0x07, 0x65, 0x00])
        case "03":
            return cleared ? frames("7E8", [0x43, 0x00])
                           : frames("7E8", [0x43, 0x02, 0x01, 0x71, 0x04, 0x20])
        case "07":
            return cleared ? frames("7E8", [0x47, 0x00]) : frames("7E8", [0x47, 0x01, 0x03, 0x05])
        case "0A":
            return frames("7E8", [0x4A, 0x01, 0x04, 0x20])
        case "04":
            cleared = true
            return frames("7E8", [0x44])
        case "0902":
            // Both engine computers report the same VIN (a swapped module would differ).
            return frames("7E8", [0x49, 0x02, 0x01] + Array(Self.vin.utf8))
                 + frames("7E9", [0x49, 0x02, 0x01] + Array(Self.vin.utf8))
        case "0904":
            return frames("7E8", [0x49, 0x04, 0x01] + Array("SIM-W16-ME-0001".utf8) + [0])
                 + frames("7E9", [0x49, 0x04, 0x01] + Array("SIM-W16-ME-0002".utf8) + [0])
        case "0906":
            return frames("7E8", [0x49, 0x06, 0x01, 0x4C, 0x9A, 0x13, 0xE7])
                 + frames("7E9", [0x49, 0x06, 0x01, 0x8B, 0x02, 0x5D, 0xF1])
        case "090A":
            return frames("7E8", [0x49, 0x0A, 0x01] + Array("ECM-EngineControl A".utf8) + [0])
                 + frames("7E9", [0x49, 0x0A, 0x01] + Array("ECM-EngineControl B".utf8) + [0])
        case "020200":
            return frames("7E8", [0x42, 0x02, 0x00, 0x01, 0x71])
        default:
            break
        }

        // Mode 06 on-board test results, from both engine computers (7E8 cyl 1–8, 7E9 cyl 9–16)
        if cmd.count == 4, cmd.hasPrefix("06"), let mid = UInt8(cmd.suffix(2), radix: 16) {
            var out: [String] = []
            if let p8 = mode06(mid) { out += frames("7E8", p8) }
            if let p9 = mode06_7e9(mid) { out += frames("7E9", p9) }
            return out.isEmpty ? ["NO DATA"] : out
        }

        // Freeze frame: 02 PID 00
        if cmd.count == 6, cmd.hasPrefix("02"), cmd.hasSuffix("00"),
           let pid = UInt8(cmd.dropFirst(2).prefix(2), radix: 16),
           let data = liveBytes(pid, t: 42) {
            return frames("7E8", [0x42, pid, 0x00] + data)
        }

        // Live data: "01" + one or more PIDs, optionally followed by a single response-count digit
        if cmd.hasPrefix("01"), cmd.count >= 4 {
            var hex = String(cmd.dropFirst(2))
            if hex.count % 2 == 1 { hex.removeLast() }          // e.g. "010C1" → "0C"
            let pids = hexBytes(hex)
            var payload: [UInt8] = [0x41]
            for pid in pids.prefix(6) {
                if let data = liveBytes(pid, t: t) { payload += [pid] + data }
            }
            return payload.count > 1 ? frames("7E8", payload) : ["NO DATA"]
        }
        return ["NO DATA"]
    }

    // MARK: - Module-addressed requests (All Modules page, Custom Readings)

    private func moduleReply(_ cmd: String) -> [String]? {
        guard let h = Int(header, radix: 16) else { return nil }
        // Simulated modules: engine, transmission, and a VW-style ABS that replies on 77D.
        let replies = ["7E0": String(format: "%03X", h + 8), "7E1": String(format: "%03X", h + 8), "713": "77D"]
        guard let reply = replies[header] else { return cmd.hasPrefix("01") ? nil : ["NO DATA"] }
        switch cmd {
        case "1902FF":
            // UDS DTCs: code hi, code lo, failure type, status
            if header == "713" { return frames(reply, [0x59, 0x02, 0xFF]) }
            if header == "7E0" {
                let codes: [UInt8] = cleared ? [] : [0x01, 0x71, 0x00, 0x89,     // P0171 confirmed, lamp
                                                     0x04, 0x20, 0x00, 0x08,     // P0420 confirmed
                                                     0x12, 0x34, 0x1C, 0x24]     // P1234-1C, manufacturer, pending/history
                return frames(reply, [0x59, 0x02, 0xFF] + codes)
            } else {
                return frames(reply, [0x59, 0x02, 0xFF] + (cleared ? [] : [0xC1, 0x00, 0x00, 0x28]))  // U0100 history
            }
        case "22F190": return frames(reply, [0x62, 0xF1, 0x90] + Array(Self.vin.utf8))
        case "22F187":
            let pn = header == "7E0" ? "SIM-ECM-0001" : header == "713" ? "SIM-ABS-0003" : "SIM-TCM-0002"
            return frames(reply, [0x62, 0xF1, 0x87] + Array(pn.utf8))
        case "22F197":
            let name = header == "7E0" ? "ENGINE" : header == "713" ? "ABS ESP" : "GEARBOX"
            return frames(reply, [0x62, 0xF1, 0x97] + Array(name.utf8))
        case "22F189": return frames(reply, [0x62, 0xF1, 0x89] + Array("0712".utf8))
        case "221001":   // demo custom reading: oil pressure in mbar, (A*256+B)/1000 → bar
            let t = Date().timeIntervalSince(start)
            let bar = 1.8 + 2.6 * min(1, speedKmh(t) / 120) + 0.05 * sin(t * 3)
            let n = Int(bar * 1000)
            return frames(reply, [0x62, 0x10, 0x01, UInt8(n >> 8), UInt8(n & 0xFF)])
        default:
            if cmd.hasPrefix("22") || cmd.hasPrefix("19") || cmd.hasPrefix("21") {
                return frames(reply, [0x7F, UInt8(cmd.prefix(2), radix: 16) ?? 0, 0x31])   // not supported
            }
            return nil
        }
    }

    // MARK: - VW TP2.0 (raw CAN frames)

    /// Simulated older-VW modules reached over TP2.0: engine, ABS, airbag, instruments, gateway.
    private static let tpModules: [UInt8: (ident: String, faults: [UInt8])] = [
        0x01: ("1K0907115AB  MED17.5 2.0l TFSI  0040", []),
        0x03: ("1K0907379AC  ESP FRONT MK60EC1  H31 0107", [0x01, 0x1B, 0x29]),     // demo fault 00283
        0x02: ("09G927750HE  AQ 250 6F  1234", []),
        0x15: ("1K0909605AB  05 AIRBAG VW8R  010 0016", [0x05, 0x82, 0x23]),       // demo fault 01410
        0x17: ("1K0920874A  KOMBI+WEGFAHRSP VDO  V05", []),
        0x19: ("1K0907530L  J533 Gateway H07  0071", []),
    ]

    /// Demo measuring blocks: engine group 1 (rpm, coolant, lambda, MAP) and transmission group 4
    /// (temperature + two oil pressures, like the Bugatti VCDS screenshot).
    private func blockFields(_ mod: UInt8, _ group: UInt8) -> [UInt8]? {
        let t = Date().timeIntervalSince(start)
        let rpm = 850 + 1500 * max(0, sin(t / 3))
        switch (mod, group) {
        case (0x01, 1):
            let b = UInt8(min(255, max(1, rpm / 0.2 / 200)))
            return [0x01, 200, b, 0x05, 10, 190, 0x0B, 100, UInt8(128 + Int(10 * sin(t))), 0x12, 25, 40]
        case (0x03, 1):                                   // four wheel speeds (km/h); rear left drops out now and then
            let v = UInt8(min(250, max(0, speedKmh(t))))
            let rl: UInt8 = Int(t) % 7 == 0 ? 0 : v
            return [0x07, 100, v, 0x07, 100, v, 0x07, 100, rl, 0x07, 100, v]
        case (0x01, 93):                                  // demo cam timing: −2.5 °KW and −3.1 °KW
            return [0x01, 200, UInt8(min(255, max(1, rpm / 40))), 0x26, 100, 103, 0x26, 100, 97, 0x25, 0, 0]
        case (0x19, 125):                                 // demo gateway installation list
            return [0x5F, 8, 69, 110, 103, 105, 110, 101, 32, 49, 0x5F, 12, 65, 66, 83, 32, 66, 114, 97, 107, 101, 115, 32, 49, 0x5F, 8, 65, 105, 114, 98, 97, 103, 32, 49]
        case (0x19, 126):
            return [0x5F, 13, 73, 110, 115, 116, 114, 117, 109, 101, 110, 116, 115, 32, 49, 0x5F, 7, 82, 97, 100, 105, 111, 32, 48]
        case (0x17, 2):                                   // demo cluster: stored mileage 123,450 km
            return [0x24, 48, 57, 0x05, 10, 190, 0x25, 0, 0, 0x25, 0, 0]
        case (0x19, 1):                                   // demo gateway battery monitor: 12.2 V, 75 %
            return [0x06, 100, 122, 0x02, 150, 250, 0x25, 0, 0, 0x25, 0, 0]
        case (0x02, 4):
            let p1 = UInt8(51 + Int(2 * sin(t))), p2 = UInt8(53 + Int(2 * sin(t + 1)))
            return [0x05, 10, 159, 0x0E, 200, p1, 0x0E, 200, p2, 0x25, 0, 0]
        default: return nil
        }
    }

    private func tp20Reply(_ cmd: String) -> [String] {
        var hex = cmd
        if hex.count % 2 == 1 { hex.removeLast() }
        let b = hexBytes(hex)
        guard let b0 = b.first else { return ["?"] }
        if header == "200" {
            guard b.count >= 7, b[1] == 0xC0, Self.tpModules[b0] != nil else { return ["NO DATA"] }
            tpModule = b0
            tpSeq = 0
            return [String(format: "%03X", 0x200 + Int(b0)) + "00D00003400701"]   // rx 300, tx 740
        }
        guard header == "740", let mod = tpModule else { return ["NO DATA"] }
        let params = "300A10F8AFF4AFF"
        switch b0 {
        case 0xA0, 0xA3: return [params]
        case 0xA8: tpModule = nil; return ["300A8"]
        default: break
        }
        guard b0 >> 4 == 0x1, b.count >= 3 else { return ["NO DATA"] }     // only single-packet requests
        let seq = b0 & 0x0F
        let len = Int(b[1]) << 8 | Int(b[2])
        let kwp = Array(b.dropFirst(3).prefix(len))
        let resp: [UInt8]
        switch kwp {
        case [0x10, 0x89]: resp = [0x50, 0x89]
        case [0x1A, 0x9B]: resp = [0x5A, 0x9B] + Array(Self.tpModules[mod]!.ident.utf8) + [0x00, 0x00, 0x03]
        case [0x18, 0x02, 0xFF, 0x00]:
            let f = Self.tpModules[mod]!.faults
            resp = [0x58, UInt8(f.count / 3)] + f
        default:
            if kwp.count == 2, kwp[0] == 0x21, let f = blockFields(mod, kwp[1]) {
                resp = [0x61, kwp[1]] + f
            } else if kwp.first == 0x21 {
                resp = [0x7F, 0x21, 0x31]
            } else {
                resp = [0x7F, kwp.first ?? 0, 0x11]
            }
        }
        var out = ["300" + String(format: "B%X", Int((seq + 1) & 0x0F))]
        var payload = [UInt8(resp.count >> 8), UInt8(resp.count & 0xFF)] + resp
        while !payload.isEmpty {
            let chunk = Array(payload.prefix(7))
            payload.removeFirst(chunk.count)
            let op: UInt8 = payload.isEmpty ? 0x10 : 0x20
            out.append("300" + ([op | tpSeq] + chunk).map { String(format: "%02X", $0) }.joined())
            tpSeq = (tpSeq + 1) & 0x0F
        }
        return out
    }

    // MARK: - Simulated car

    private func batteryVolts() -> Double {
        lock.lock(); let c = crankAt; lock.unlock()
        let noise = Double.random(in: -0.03...0.03)
        guard let c else { return 13.9 + noise }
        let dt = Date().timeIntervalSince(c)
        switch dt {
        case ..<0: return 12.55 + noise                          // engine off, resting
        case ..<0.25: return 9.85 + noise                        // starter inrush dip
        case ..<1.2: return 10.55 + 0.15 * sin(dt * 40) + noise  // cranking
        case ..<2.5: return 10.6 + (dt - 1.2) / 1.3 * 3.55 + noise
        case ..<20: return 14.15 + noise
        default:
            lock.lock(); crankAt = nil; lock.unlock()
            return 13.9 + noise
        }
    }

    /// 36 s loop: 6 s idle, 12 s launch, 12 s braking, 6 s idle.
    private func speedKmh(_ t: Double) -> Double {
        let p = t.truncatingRemainder(dividingBy: 36)
        switch p {
        case ..<6: return 0
        case ..<18: return min(255, 330 * (1 - exp(-(p - 6) / 6)))
        case ..<30:
            let top = min(255, 330 * (1 - exp(-2.0)))
            return max(0, top * (1 - (p - 18) / 12))
        default: return 0
        }
    }

    private func liveBytes(_ pid: UInt8, t: Double) -> [UInt8]? {
        let v = speedKmh(t)
        let p = t.truncatingRemainder(dividingBy: 36)
        let launching = p >= 6 && p < 18
        let rev = launching ? 0.95 : (v > 0 ? 0.15 : 0.1 + 0.1 * sin(t / 2))
        let rpm = v > 0 ? 1400 + v.truncatingRemainder(dividingBy: 60) / 60 * 4800 : 950 + rev * 300
        let warm = min(1, t / 90)                        // warms up over ~90 s
        func u8(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x.rounded()))) }
        func u16(_ x: Double) -> [UInt8] {
            let n = Int(max(0, min(65535, x.rounded())))
            return [UInt8(n >> 8), UInt8(n & 0xFF)]
        }
        /// Exhaust/turbine temps use (°C + 40) × 10 in a 16-bit word.
        func t16(_ c: Double) -> [UInt8] { u16((c + 40) * 10) }
        let braking = p >= 18 && p < 30
        switch pid {
        case 0x03:                                                          // fuel system status
            let status: UInt8 = warm < 0.35 ? 1 : ((launching || braking) ? 4 : 2)
            return [status, 0]
        case 0x24, 0x28:                                                     // wideband λ + voltage
            let wobble: Double = sin(t * 3 + Double(pid)) * 0.012
            let lambda: Double = launching ? 0.86 : (warm < 0.35 ? 0.95 : 1.0 + wobble)
            return u16(lambda * 32768) + u16(1.1 * 8192)
        case 0x3E, 0x3F: return u16((360 + warm * 240 + 40) * 10)
        case 0x44: return u16((launching ? 0.86 : 1.0) * 32768)              // commanded λ
        case 0x4D: return u16(cleared ? 0 : 41)                             // minutes with MIL on
        case 0x4E: return u16(cleared ? 0 : 74)                             // minutes since clear
        case 0x51: return [1]                                               // gasoline
        case 0x61: return [u8(125 + rev * 100)]                             // driver-demand torque %
        case 0x62: return [u8(125 + rev * 96)]                              // actual torque %
        case 0x63: return u16(1500)                                         // reference torque N·m
        case 0x6F: return [0x03, 99, 98]                                    // compressor inlet kPa
        case 0x70:                                                          // boost control A/B, kPa × 32
            let cmd = (99 + rev * 150) * 32, act = (99 + rev * 145) * 32
            let body: [UInt8] = [0x1B] + u16(cmd) + u16(act) + u16(cmd) + u16(act - 32)
            return body + [0x0A]                                            // both banks closed loop
        case 0x72: return [0x0F, u8(rev * 60 * 2.55), u8(rev * 58 * 2.55), u8(rev * 60 * 2.55), u8(rev * 57 * 2.55)]
        case 0x77: return [0x05, u8(40 + 35 + rev * 20), 0, u8(40 + 36 + rev * 21), 0]   // B1S1, B2S1
        case 0x74: return [0x03] + u16((24_000 + rev * 125_000) / 10) + u16((23_500 + rev * 124_000) / 10)
        case 0x75, 0x76:                                                    // turbo A / B temperatures
            let b: Double = pid == 0x76 ? 4 : 0
            let inlet: UInt8 = u8(64)
            let outlet: UInt8 = u8(75 + rev * 115 + b)
            let head: [UInt8] = [0x0F, inlet, outlet]
            return head + t16(420 + rev * 520 + b) + t16(360 + rev * 430 + b)
        case 0x78, 0x79:                                                    // EGT, 4 sensors per bank
            let bank: Double = pid == 0x79 ? 12 : 0
            var out: [UInt8] = [0x0F]
            for i in 0..<4 { out += t16(430 + rev * 480 + bank - Double(i) * 35) }
            return out
        case 0x87: return [0x03] + u16((99 + rev * 145) * 32) + u16((99 + rev * 143) * 32)   // boost, kPa abs
        case 0xA6:                                                          // odometer, 0.1 km
            let n = 84_123 + Int(t / 10)
            return [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        case 0x04: return [u8((15 + rev * 80) * 2.55)]
        case 0x05: return [u8(40 + 25 + warm * 65)]                // 25 → 90 °C
        case 0x06: return [u8(128 + sin(t * 2) * 6)]
        case 0x07: return [u8(128 + 14)]                           // +11 % (lean bank 1)
        case 0x08: return [u8(128 + sin(t * 2.3) * 5)]
        case 0x09: return [u8(128 + 2)]
        case 0x0B: return [u8(32 + rev * 220)]
        case 0x0C: return u16(rpm * 4)
        case 0x0D: return [u8(v)]
        case 0x0E: return [u8((12 + rev * 10 + 64) * 2)]
        case 0x0F: return [u8(40 + 24)]
        case 0x10: return u16((12 + rev * 600) * 100)
        case 0x11: return [u8((14 + rev * 80) * 2.55)]
        case 0x1F: return u16(t)
        case 0x21: return u16(cleared ? 0 : 18)
        case 0x2F: return [u8(61 * 2.55)]
        // Demo of a pre-purchase red flag: codes were wiped 3 warm-ups / 29 km ago.
        case 0x30: return [cleared ? 0 : 3]
        case 0x31: return u16(cleared ? 0 : 29)
        case 0x33: return [101]
        case 0x3C, 0x3D: return u16((420 + warm * 280 + 40) * 10)
        case 0x42: return u16(batteryVolts() * 1000)
        case 0x46: return [u8(40 + 22)]
        case 0x49: return [u8((15 + rev * 80) * 2.55)]
        case 0x5C: return [u8(40 + 20 + warm * 75)]
        case 0x14...0x1B: return [u8(0.45 * 200 + sin(t * 5 + Double(pid)) * 70), 0xFF]
        default: return nil
        }
    }

    /// One Mode 06 test record: MID, TID, unit/scaling, value, min, max.
    private func t6(_ mid: UInt8, _ tid: UInt8, _ uas: UInt8, _ v: Int, _ lo: Int, _ hi: Int) -> [UInt8] {
        func w(_ x: Int) -> [UInt8] { let u = UInt16(bitPattern: Int16(truncatingIfNeeded: x)); return [UInt8(u >> 8), UInt8(u & 0xFF)] }
        return [mid, tid, uas] + w(v) + w(lo) + w(hi)
    }

    /// Engine computer A (7E8): cylinders 1–8. Catalyst B1 failing, bank-1 fuel system close to
    /// its limit, and cylinder 5 logging misfires — consistent with the codes above.
    private func mode06(_ mid: UInt8) -> [UInt8]? {
        switch mid {
        case 0x00: return [0x46, 0x00, 0xCC, 0x00, 0x00, 0x01]   // 01 02 05 06, +0x20 range
        case 0x20: return [0x46, 0x20, 0xC0, 0x00, 0x00, 0x01]   // 21 22, +0x40
        case 0x40: return [0x46, 0x40, 0x80, 0x00, 0x00, 0x01]   // 41, +0x60
        case 0x60: return [0x46, 0x60, 0x00, 0x00, 0x00, 0x01]   // +0x80
        case 0x80: return [0x46, 0x80, 0x80, 0x00, 0x00, 0x01]   // 81, +0xA0
        case 0xA0: return [0x46, 0xA0, 0xFF, 0x80, 0x00, 0x00]   // A1–A9 (general + cylinders 1–8)
        case 0x01: return [0x46] + t6(0x01, 0x01, 0x0B, 450, 400, 500) + t6(0x01, 0x05, 0x10, 96, 0, 150)
        case 0x05: return [0x46] + t6(0x05, 0x01, 0x0B, 455, 400, 500) + t6(0x05, 0x05, 0x10, 71, 0, 150)
        case 0x02: return [0x46] + t6(0x02, 0x07, 0x0B, 62, 0, 400)
        case 0x06: return [0x46] + t6(0x06, 0x08, 0x0B, 812, 700, 1100)
        case 0x21: return [0x46] + t6(0x21, 0x80, 0x01, 421, 0, 400)              // FAIL
        case 0x22: return [0x46] + t6(0x22, 0x80, 0x01, 152, 0, 400)
        case 0x41: return [0x46] + t6(0x41, 0x81, 0x10, 3200, 0, 30000)
        case 0x81: return [0x46] + t6(0x81, 0x80, 0xAF, 1420, -2000, 1500)        // near limit
        case 0xA1: return [0x46] + t6(0xA1, 0x0B, 0x24, 10, 0, 0) + t6(0xA1, 0x0C, 0x24, 24, 0, 0)
        case 0xA2...0xA9:                                        // cylinders 1–8
            let cyl = Int(mid) - 0xA1
            let (avg, last) = cyl == 5 ? (9, 24) : (0, 0)
            return [0x46] + t6(mid, 0x0B, 0x24, avg, 0, 0) + t6(mid, 0x0C, 0x24, last, 0, 0)
        default: return nil
        }
    }

    /// Engine computer B (7E9): cylinders 9–16. Reports its own misfire monitors, so the app's
    /// multi-ECU read shows all 16 cylinders. Here cylinder 15 is logging misfires too.
    private func mode06_7e9(_ mid: UInt8) -> [UInt8]? {
        switch mid {
        case 0x00, 0x20, 0x40, 0x60, 0x80:
            return mode06(mid)                                   // same bitmap chain as bank A
        case 0xA0: return [0x46, 0xA0, 0xFF, 0x80, 0x00, 0x00]   // A1–A9 (general + its 8 cylinders)
        case 0xA1: return [0x46] + t6(0xA1, 0x0B, 0x24, 7, 0, 0) + t6(0xA1, 0x0C, 0x24, 18, 0, 0)
        case 0xA2...0xA9:                                        // local 1–8 → global 9–16
            let local = Int(mid) - 0xA1
            let (avg, last) = local == 7 ? (6, 18) : (0, 0)      // local cyl 7 → global cylinder 15
            return [0x46] + t6(mid, 0x0B, 0x24, avg, 0, 0) + t6(mid, 0x0C, 0x24, last, 0, 0)
        default: return nil
        }
    }

    /// Encode a payload as ISO-TP frames the way an ELM327 prints them (header + 8 bytes).
    private func frames(_ header: String, _ payload: [UInt8]) -> [String] {
        func line(_ bytes: [UInt8]) -> String {
            let padded = bytes + Array(repeating: 0x55, count: max(0, 8 - bytes.count))
            return header + padded.map { String(format: "%02X", $0) }.joined()
        }
        if payload.count <= 7 {
            return [line([UInt8(payload.count)] + payload)]
        }
        var out = [line([0x10 | UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
                        + payload.prefix(6))]
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

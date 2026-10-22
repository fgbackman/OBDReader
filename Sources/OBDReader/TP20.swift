import Foundation
import SwiftUI

// VW Transport Protocol 2.0 (TP2.0) with KWP2000 — how VW, Audi, Skoda and Seat cars from roughly
// 2004–2014 talk to their non-engine modules (ABS, airbag, instruments, gateway …).
// Reference: icanhack.nl/knowledge-base/diagnostics/vw-tp20 and jazdw.net/tp20.
//
// Read-only. Per module: open a channel, enter VW's standard diagnostic session (10 89, temporary),
// read identification (1A 9B) and fault codes (18 02 FF 00), close the channel.
// The immobilizer (address 25) is never contacted.

struct TP20Fault: Identifiable, Hashable {
    let code: Int          // 2-byte fault number, shown in decimal like VW's 5-digit codes
    let status: UInt8
    var id: String { "\(code)-\(status)" }
    var display: String { String(format: "%05d", code) }
    /// Generic P-code for engine faults (16384–17383 → P0xxx, 17408–18407 → P1xxx).
    var pCode: String? { VAGCodes.pCode(code) }
    var description: String { VAGCodes.describe(code) }
    var causes: String? { VAGCodes.causes(code) }
}

/// Plain-English text for VW-group fault numbers.
/// Engine faults: the 5-digit number is the P-code plus a fixed offset — 16384 for P0xxx
/// (16684 = P0300) and 16408 for P1xxx (17965 = P1557). Sources: vag-coding.net fault-code list,
/// stedmansgarage.co.uk VW/Audi code tables (both show the same offsets).
/// Other modules use VW's own numbers; a short list of common ones is included, in our wording.
enum VAGCodes {
    static func pCode(_ code: Int) -> String? {
        switch code {
        case 16384...17383: return String(format: "P%04d", code - 16384)
        case 17408...18407: return String(format: "P%04d", code - 16408)
        default: return nil
        }
    }

    static func describe(_ code: Int) -> String {
        if let p = pCode(code) {
            if p.hasPrefix("P1") { return "\(p) — VW-specific engine fault; see VW repair information" }
            let d = DTCDatabase.describe(p)
            return d.hasPrefix("No generic description") ? "\(p) — engine fault" : "\(p) — \(d)"
        }
        return names[code] ?? "VW fault \(String(format: "%05d", code)) — look it up in VW repair information"
    }

    static func causes(_ code: Int) -> String? {
        if let p = pCode(code) { return DTCDatabase.causes(p) }
        return commonCauses[code]
    }

    static let names: [Int: String] = [
        3: "Control module (internal fault)",
        283: "ABS wheel speed sensor, front left (G47)",
        285: "ABS wheel speed sensor, front right (G45)",
        287: "ABS wheel speed sensor, rear right (G44)",
        290: "ABS wheel speed sensor, rear left (G46)",
        532: "Supply voltage B+",
        588: "Airbag igniter, driver side (N95)",
        589: "Airbag igniter, passenger side (N131)",
        625: "Speed signal",
        668: "Supply voltage terminal 30",
        778: "Steering angle sensor (G85)",
        1042: "Control module not coded",
        1044: "Control module incorrectly coded",
        1130: "ABS operation",
        1217: "Side airbag igniter, driver side (N199)",
        1218: "Side airbag igniter, passenger side (N200)",
        1276: "ABS hydraulic pump (V64)",
        1299: "Diagnostic interface for data bus (J533)",
        1312: "Powertrain data bus",
        1314: "Engine control module — no communication",
        1316: "ABS control module — no communication",
        1317: "Control module in instrument cluster (J285)",
        1321: "Airbag control module (J234)",
        1435: "Brake pressure sensor 1 (G201)",
    ]

    static let commonCauses: [Int: String] = [
        283: "Wheel speed sensor, its wiring or connector at that wheel, a dirty or damaged tone ring, or a worn wheel bearing.",
        285: "Wheel speed sensor, its wiring or connector at that wheel, a dirty or damaged tone ring, or a worn wheel bearing.",
        287: "Wheel speed sensor, its wiring or connector at that wheel, a dirty or damaged tone ring, or a worn wheel bearing.",
        290: "Wheel speed sensor, its wiring or connector at that wheel, a dirty or damaged tone ring, or a worn wheel bearing.",
        532: "Low battery or charging voltage, or a poor power/ground connection to the module.",
        668: "Low battery voltage, a weak battery, or a poor power/ground connection.",
        588: "Steering-wheel clock spring or airbag connector; never probe airbag circuits with a test light.",
        589: "Passenger airbag connector or wiring.",
        1217: "Connector under the driver's seat (often disturbed when the seat is moved) or the side-airbag wiring.",
        1218: "Connector under the passenger seat or the side-airbag wiring.",
        778: "Steering angle sensor not calibrated (common after battery disconnects or alignment work) or a failing sensor.",
        1314: "Low voltage, CAN wiring, or the engine module was not awake when others checked it.",
        1316: "Low voltage, ABS module fuse or connector, CAN wiring, or the ABS module itself.",
        1276: "ABS pump motor, its fuse or relay, or the pump's power/ground connection.",
        1044: "Module coding doesn't match the car's equipment — a shop with VW tools needs to check it.",
    ]
}

struct TP20Report: Identifiable {
    let address: UInt8
    var identification: [String] = []
    var faults: [TP20Fault] = []
    var faultsRead = false
    var note: String?
    var id: UInt8 { address }
    var addressText: String { String(format: "%02X", address) }
    var name: String { TP20.names[address] ?? "Module" }
}

enum TP20Error: LocalizedError {
    case timeout, closedByModule
    var errorDescription: String? {
        switch self {
        case .timeout: return "The module stopped answering."
        case .closedByModule: return "The module closed the channel."
        }
    }
}

enum TP20 {
    /// VW's standard diagnostic address names (the numbers VCDS uses).
    static let names: [UInt8: String] = [
        0x01: "Engine", 0x02: "Auto trans", 0x03: "ABS brakes", 0x08: "Auto HVAC", 0x09: "Central electrics",
        0x13: "Distance regulation", 0x15: "Airbags", 0x16: "Steering wheel", 0x17: "Instruments",
        0x19: "CAN gateway", 0x22: "AWD", 0x36: "Seat adjustment driver", 0x42: "Door electronics driver",
        0x44: "Steering assist", 0x46: "Central convenience", 0x52: "Door electronics passenger",
        0x53: "Parking brake", 0x55: "Headlight range", 0x56: "Radio", 0x62: "Door rear left",
        0x65: "Tyre pressure", 0x72: "Door rear right", 0x76: "Park assist", 0x77: "Telephone",
    ]

    /// Every address except the immobilizer (25), which this app never contacts.
    static let sweepAddresses: [UInt8] = (0x01...0x7F).map { UInt8($0) }.filter { $0 != 0x25 }

    /// Printable text runs from an identification reply.
    static func textRuns(_ bytes: [UInt8]) -> [String] {
        var runs: [String] = []
        var cur: [UInt8] = []
        for b in bytes {
            if (0x20...0x7E).contains(b) { cur.append(b) } else {
                if !cur.isEmpty { runs.append(String(decoding: cur, as: UTF8.self)); cur = [] }
            }
        }
        if !cur.isEmpty { runs.append(String(decoding: cur, as: UTF8.self)) }
        return runs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
    }

    /// 58 n (hi lo status)×n
    static func parseFaults(_ r: [UInt8]) -> [TP20Fault]? {
        guard r.count >= 2, r[0] == 0x58 else { return nil }
        var out: [TP20Fault] = []
        var i = 2
        while i + 2 < r.count {
            let code = Int(r[i]) << 8 | Int(r[i + 1])
            if code != 0xFFFF && code != 0 { out.append(TP20Fault(code: code, status: r[i + 2])) }
            i += 3
        }
        return out
    }
}

extension ELM327 {
    /// Raw CAN mode for TP2.0: no ISO-TP formatting, fixed timing.
    func tp20Begin() throws {
        _ = try raw("ATCAF0")
        _ = try raw("ATAT0")
    }

    func tp20End() {
        _ = try? raw("ATST32")
        _ = try? raw("ATAT1")
        _ = try? raw("ATCAF1")
        _ = try? raw("ATCRA")
        _ = try? raw("ATAR")
        _ = try? raw("ATSH7DF")
    }

    /// Send one raw frame (current header) and return the frames received (11-bit ID, data).
    func rawFrame(_ data: [UInt8], timeout: TimeInterval = 2) throws -> [(id: String, data: [UInt8])] {
        let lines = clean(try raw(data.map { String(format: "%02X", $0) }.joined(), timeout: timeout))
        return lines.compactMap { l in
            guard l.count >= 5, isHex(l), l.count % 2 == 1 else { return nil }
            return (id: String(l.prefix(3)), data: hexBytes(String(l.dropFirst(3))))
        }
    }
}

/// One TP2.0 channel to one module. Synchronous: run it on the adapter queue.
final class TP20Channel: @unchecked Sendable {
    let elm: ELM327
    let address: UInt8
    private(set) var txID = ""
    private(set) var rxID = ""
    private var txSeq: UInt8 = 0

    init(elm: ELM327, address: UInt8) { self.elm = elm; self.address = address }

    /// Channel setup on 0x200; the module answers on 0x200 + address. False if nothing answers.
    func open() throws -> Bool {
        _ = try elm.raw("ATST19")                                   // ~100 ms: setup replies are quick
        _ = try elm.raw("ATSH200")
        _ = try elm.raw(String(format: "ATCRA%03X", 0x200 + Int(address)))
        let frames = try elm.rawFrame([address, 0xC0, 0x00, 0x10, 0x00, 0x03, 0x01], timeout: 1.5)
        guard let d = frames.map({ $0.data }).first(where: { $0.count >= 6 && $0[1] == 0xD0 }) else { return false }
        // Bytes 2–3: ID the tester receives on; 4–5: ID the tester transmits on (low byte, then high bits).
        rxID = String(format: "%03X", Int(d[2]) | (Int(d[3] & 0x07) << 8))
        txID = String(format: "%03X", Int(d[4]) | (Int(d[5] & 0x07) << 8))
        _ = try elm.raw("ATST7D")                                   // ~500 ms for data
        _ = try elm.raw("ATSH" + txID)
        _ = try elm.raw("ATCRA" + rxID)
        txSeq = 0
        let p = try elm.rawFrame([0xA0, 0x0F, 0x8A, 0xFF, 0x32, 0xFF])
        if !p.contains(where: { $0.data.first == 0xA1 }) { close(); return false }
        return true
    }

    func close() {
        _ = try? elm.rawFrame([0xA8], timeout: 1)
    }

    private func send(_ frame: [UInt8]) throws -> [[UInt8]] {
        try elm.rawFrame(frame).filter { $0.id == rxID }.map { $0.data }
    }

    /// Send one KWP2000 request and return the module's reply (service byte first).
    func request(_ kwp: [UInt8], timeout: TimeInterval = 4) throws -> [UInt8] {
        var payload = [UInt8(kwp.count >> 8), UInt8(kwp.count & 0xFF)] + kwp
        var queue: [[UInt8]] = []
        while !payload.isEmpty {
            let chunk = Array(payload.prefix(7))
            payload.removeFirst(chunk.count)
            let op: UInt8 = payload.isEmpty ? 0x10 : 0x20           // last packet waits for ACK
            queue += try send([op | (txSeq & 0x0F)] + chunk)
            txSeq = (txSeq + 1) & 0x0F
        }

        var message: [UInt8] = []
        var expected: Int?
        var deadline = Date().addingTimeInterval(timeout)
        while true {
            while !queue.isEmpty {
                if Date() > deadline { throw TP20Error.timeout }
                let f = queue.removeFirst()
                guard let b0 = f.first else { continue }
                let op = b0 >> 4, seq = b0 & 0x0F
                switch op {
                case 0x0, 0x1, 0x2, 0x3:
                    var data = Array(f.dropFirst())
                    if expected == nil {
                        guard data.count >= 2 else { continue }
                        expected = Int(data[0]) << 8 | Int(data[1])
                        data.removeFirst(2)
                        message = []
                    }
                    message += data
                    if op == 0x0 || op == 0x1 { queue += try send([0xB0 | ((seq + 1) & 0x0F)]) }
                    if op == 0x1 || op == 0x3 {
                        let m = Array(message.prefix(expected ?? message.count))
                        expected = nil
                        if m.count >= 3, m[0] == 0x7F, m[2] == 0x78 {           // busy: keep waiting
                            deadline = Date().addingTimeInterval(timeout)
                            continue
                        }
                        return m
                    }
                case 0xA:
                    if b0 == 0xA8 { throw TP20Error.closedByModule }
                default:
                    continue   // ACKs (B_ / 9_) for our own packets
                }
            }
            if Date() > deadline { throw TP20Error.timeout }
            queue += try send([0xA3])    // channel test: keeps the channel open and listens again
        }
    }
}

extension ELM327 {
    /// Read one module over TP2.0. nil if nothing answers at that address.
    func tp20Read(_ address: UInt8) -> TP20Report? {
        let ch = TP20Channel(elm: self, address: address)
        guard (try? ch.open()) == true else { return nil }
        defer { ch.close() }
        var rep = TP20Report(address: address)
        do {
            _ = try ch.request([0x10, 0x89])
            let id = try ch.request([0x1A, 0x9B])
            if id.first == 0x5A { rep.identification = TP20.textRuns(Array(id.dropFirst(2))) }
            var r = try ch.request([0x18, 0x02, 0xFF, 0x00])
            if r.first == 0x7F { r = try ch.request([0x18, 0x00, 0xFF, 0x00]) }
            if let f = TP20.parseFaults(r) {
                rep.faults = f
                rep.faultsRead = true
            } else if r.first == 0x7F, r.count >= 3 {
                rep.note = "Answered but refused the fault-code request (\(UDS.nrcText(r[2])))."
            }
        } catch {
            rep.note = error.localizedDescription
        }
        return rep
    }
}

// MARK: - View

struct TP20Card: View {
    @EnvironmentObject var s: VehicleSession

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Older VW / Audi / Skoda / Seat (TP2.0)").font(.headline)
                    Spacer()
                    if s.tp20Running {
                        Button("Stop", role: .destructive) { s.stopTP20() }
                    } else {
                        Button("Scan TP2.0 modules") { Task { await s.scanTP20() } }
                            .disabled(s.busy != nil || !s.isCAN || s.protocolName.contains("29-bit"))
                    }
                }
                Text("For VW-group cars from about 2004–2014, whose ABS, airbag, instruments and other modules use VW's older TP2.0 protocol. Opens a channel to each address 01–7F, reads its part number and fault codes, and closes it. Read-only; the immobilizer (25) is skipped. About 1–2 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                if let p = s.tp20Progress { ProgressView(value: p) }
                ForEach(s.tp20Reports) { TP20ModuleCard(report: $0) }
                if s.tp20Progress == nil, let t = s.lastTP20Scan, s.tp20Reports.isEmpty {
                    Text("No module answered at \(t.formatted(date: .omitted, time: .shortened)). This car may not use TP2.0.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct TP20ModuleCard: View {
    let report: TP20Report
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(report.addressText) – \(report.name)").font(.callout.bold())
                Spacer()
                if report.faultsRead {
                    Text(report.faults.isEmpty ? "No faults" : "\(report.faults.count) fault\(report.faults.count == 1 ? "" : "s")")
                        .font(.caption.bold())
                        .foregroundStyle(report.faults.isEmpty ? Color.green : Color.orange)
                }
            }
            if !report.identification.isEmpty {
                Text(report.identification.joined(separator: " · ")).font(.caption.monospaced())
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(report.faults) { f in
                HStack(alignment: .top, spacing: 12) {
                    Text(f.display).font(.system(.body, design: .monospaced).bold()).foregroundStyle(.orange)
                        .frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.description)
                        if let c = f.causes {
                            Text("Common causes: \(c)").font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(String(format: "status %02X", f.status)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if let n = report.note { Text(n).font(.caption).foregroundStyle(.secondary) }
            Divider()
        }
    }
}

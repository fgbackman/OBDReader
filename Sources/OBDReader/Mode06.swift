import Foundation

/// One on-board monitor test result (OBD-II Mode 06, CAN format).
/// The car runs these self-tests while driving and stores the measured value next to the
/// pass/fail limits — so a part that is drifting toward its limit shows up before a code sets.
struct TestResult: Identifiable, Codable, Hashable {
    let mid: UInt8       // which monitor (catalyst bank 1, O2 sensor B1S1, misfire cyl 3…)
    let tid: UInt8       // which test inside that monitor
    let uasid: UInt8     // unit & scaling ID
    let raw: Int
    let rawMin: Int
    let rawMax: Int
    var ecu: String = ""     // which control unit answered (e.g. "7E8", "7E9")
    var bankOffset: Int = 0  // added to a per-cylinder misfire number; a second engine ECU → 8, so its cyl 1 shows as 9

    var id: String { "\(ecu)-\(String(format: "%02X-%02X", Int(mid), Int(tid)))" }

    var monitorName: String {
        if let c = cylinder { return "Misfire cylinder \(c)" }
        return Mode06.monitorName(mid)
    }
    var testName: String { Mode06.testName(mid: mid, tid: tid) }

    var isMisfireCounter: Bool { (0xA1...0xAD).contains(mid) && (tid == 0x0B || tid == 0x0C) }
    /// Cylinder number for per-cylinder misfire monitors (A2 = cylinder 1 … AD = cylinder 12),
    /// shifted by bankOffset so a second engine computer's cylinders read 9–16.
    var cylinder: Int? { (0xA2...0xAD).contains(mid) ? Int(mid) - 0xA1 + bankOffset : nil }
    var hasLimits: Bool { !(rawMin == 0 && rawMax == 0) && !isMisfireCounter }
    var passed: Bool { !hasLimits || (raw >= rawMin && raw <= rawMax) }

    /// Distance to the nearest real limit as a fraction of the allowed range (0 = on the limit).
    /// One-sided tests (min 0 or max at the top of the range) only count the meaningful side.
    var margin: Double? {
        guard hasLimits, rawMax > rawMin else { return nil }
        let span = Double(rawMax - rawMin)
        var distances: [Double] = []
        if rawMin != 0 && rawMin != -32768 { distances.append(Double(raw - rawMin)) }
        if rawMax != 0xFFFF && rawMax != 32767 { distances.append(Double(rawMax - raw)) }
        guard let d = distances.min() else { return nil }
        return max(0, d) / span
    }
    /// Passed, but within 10 % of a limit.
    var nearLimit: Bool { passed && (margin.map { $0 < 0.1 } ?? false) }

    var scaled: (value: Double, min: Double, max: Double, unit: String) {
        let s = Mode06.scaling(uasid)
        func f(_ r: Int) -> Double { Double(r) * s.factor + s.offset }
        return (f(raw), f(rawMin), f(rawMax), s.unit)
    }

    func formatted(_ v: Double) -> String {
        let unit = scaled.unit
        let digits = abs(v) >= 100 || v == v.rounded() ? 0 : (abs(v) >= 1 ? 2 : 3)
        return String(format: "%.\(digits)f", v) + (unit.isEmpty ? "" : " \(unit)")
    }
}

enum Mode06 {
    /// Parse a Mode 06 reply: [46, MID, TID, UASID, val(2), min(2), max(2), MID, TID, …]
    static func parse(_ frame: [UInt8], ecu: String = "", bankOffset: Int = 0) -> [TestResult] {
        guard frame.first == 0x46 else { return [] }
        var out: [TestResult] = []
        var i = 1
        while i + 9 <= frame.count {
            let mid = frame[i], tid = frame[i + 1], uas = frame[i + 2]
            func word(_ k: Int) -> Int {
                let u = Int(frame[i + k]) << 8 | Int(frame[i + k + 1])
                return uas >= 0x80 ? Int(Int16(bitPattern: UInt16(u))) : u
            }
            out.append(TestResult(mid: mid, tid: tid, uasid: uas, raw: word(3), rawMin: word(5), rawMax: word(7),
                                  ecu: ecu, bankOffset: bankOffset))
            i += 9
        }
        return out
    }

    // MARK: Names (SAE J1979 OBD Monitor IDs)

    static func monitorName(_ mid: UInt8) -> String {
        let bankSensor = ["B1S1", "B1S2", "B1S3", "B1S4", "B2S1", "B2S2", "B2S3", "B2S4"]
        switch mid {
        case 0x01...0x08: return "Oxygen sensor \(bankSensor[Int(mid) - 1])"
        case 0x21...0x24: return "Catalyst bank \(Int(mid) - 0x20)"
        case 0x31, 0x32: return "EGR bank \(Int(mid) - 0x30)"
        case 0x35, 0x36: return "Variable valve timing bank \(Int(mid) - 0x34)"
        case 0x39: return "EVAP leak check (0.150\")"
        case 0x3A: return "EVAP leak check (0.090\")"
        case 0x3B: return "EVAP leak check (0.040\")"
        case 0x3C: return "EVAP leak check (0.020\")"
        case 0x3D: return "EVAP purge flow"
        case 0x41...0x48: return "O2 sensor heater \(bankSensor[Int(mid) - 0x41])"
        case 0x61...0x64: return "Heated catalyst bank \(Int(mid) - 0x60)"
        case 0x71...0x74: return "Secondary air \(Int(mid) - 0x70)"
        case 0x81...0x84: return "Fuel system bank \(Int(mid) - 0x80)"
        case 0x85...0x88: return "Boost pressure control bank \(Int(mid) - 0x84)"
        case 0x90, 0x91: return "NOx adsorber bank \(Int(mid) - 0x8F)"
        case 0x98, 0x99: return "NOx/SCR catalyst bank \(Int(mid) - 0x97)"
        case 0xA1: return "Misfire (general)"
        case 0xA2...0xAD: return "Misfire cylinder \(Int(mid) - 0xA1)"
        case 0xB0, 0xB1: return "Particulate filter bank \(Int(mid) - 0xAF)"
        default: return String(format: "Monitor $%02X", Int(mid))
        }
    }

    static func testName(mid: UInt8, tid: UInt8) -> String {
        switch tid {
        case 0x01: return "Rich-to-lean threshold voltage"
        case 0x02: return "Lean-to-rich threshold voltage"
        case 0x03: return "Low voltage for switch-time calc"
        case 0x04: return "High voltage for switch-time calc"
        case 0x05: return "Rich-to-lean switch time"
        case 0x06: return "Lean-to-rich switch time"
        case 0x07: return "Minimum sensor voltage"
        case 0x08: return "Maximum sensor voltage"
        case 0x09: return "Time between transitions"
        case 0x0A: return "Sensor period"
        case 0x0B: return "Misfires, average of last 10 drives"
        case 0x0C: return "Misfires, last/current drive"
        default: return String(format: "Test $%02X (manufacturer-defined)", Int(tid))
        }
    }

    // MARK: Unit & scaling IDs (SAE J1979 Appendix E — common subset)

    struct Scaling { let factor: Double; let offset: Double; let unit: String }

    static func scaling(_ id: UInt8) -> Scaling {
        switch id {
        // Unsigned
        case 0x01: return Scaling(factor: 1, offset: 0, unit: "")
        case 0x02: return Scaling(factor: 0.1, offset: 0, unit: "")
        case 0x03: return Scaling(factor: 0.01, offset: 0, unit: "")
        case 0x04: return Scaling(factor: 0.001, offset: 0, unit: "")
        case 0x05: return Scaling(factor: 0.0000305, offset: 0, unit: "")
        case 0x06: return Scaling(factor: 0.000305, offset: 0, unit: "")
        case 0x07: return Scaling(factor: 0.25, offset: 0, unit: "rpm")
        case 0x08: return Scaling(factor: 0.01, offset: 0, unit: "km/h")
        case 0x09: return Scaling(factor: 1, offset: 0, unit: "km/h")
        case 0x0A: return Scaling(factor: 0.000122, offset: 0, unit: "V")
        case 0x0B: return Scaling(factor: 0.001, offset: 0, unit: "V")
        case 0x0C: return Scaling(factor: 0.01, offset: 0, unit: "V")
        case 0x0D: return Scaling(factor: 0.00390625, offset: 0, unit: "mA")
        case 0x0E: return Scaling(factor: 0.001, offset: 0, unit: "A")
        case 0x0F: return Scaling(factor: 0.01, offset: 0, unit: "A")
        case 0x10: return Scaling(factor: 1, offset: 0, unit: "ms")
        case 0x11: return Scaling(factor: 100, offset: 0, unit: "ms")
        case 0x12: return Scaling(factor: 1, offset: 0, unit: "s")
        case 0x13: return Scaling(factor: 1, offset: 0, unit: "mΩ")
        case 0x14: return Scaling(factor: 1, offset: 0, unit: "Ω")
        case 0x15: return Scaling(factor: 1, offset: 0, unit: "kΩ")
        case 0x16: return Scaling(factor: 0.1, offset: -40, unit: "°C")
        case 0x17: return Scaling(factor: 0.01, offset: 0, unit: "kPa")
        case 0x18: return Scaling(factor: 0.0117, offset: 0, unit: "kPa")
        case 0x19: return Scaling(factor: 0.079, offset: 0, unit: "kPa")
        case 0x1A: return Scaling(factor: 1, offset: 0, unit: "kPa")
        case 0x1B: return Scaling(factor: 10, offset: 0, unit: "kPa")
        case 0x1C: return Scaling(factor: 0.01, offset: 0, unit: "°")
        case 0x1D: return Scaling(factor: 0.5, offset: 0, unit: "°")
        case 0x1E: return Scaling(factor: 0.0000305, offset: 0, unit: "λ")
        case 0x1F: return Scaling(factor: 0.05, offset: 0, unit: "A/F")
        case 0x20: return Scaling(factor: 0.0039062, offset: 0, unit: "")
        case 0x21: return Scaling(factor: 1, offset: 0, unit: "mHz")
        case 0x22: return Scaling(factor: 1, offset: 0, unit: "Hz")
        case 0x23: return Scaling(factor: 1, offset: 0, unit: "kHz")
        case 0x24: return Scaling(factor: 1, offset: 0, unit: "counts")
        case 0x25: return Scaling(factor: 1, offset: 0, unit: "km")
        case 0x27: return Scaling(factor: 0.01, offset: 0, unit: "g/s")
        case 0x28: return Scaling(factor: 1, offset: 0, unit: "g/s")
        case 0x2F: return Scaling(factor: 0.01, offset: 0, unit: "%")
        case 0x30: return Scaling(factor: 0.001526, offset: 0, unit: "%")
        case 0x31: return Scaling(factor: 0.001, offset: 0, unit: "L")
        case 0x34: return Scaling(factor: 1, offset: 0, unit: "min")
        case 0x35: return Scaling(factor: 10, offset: 0, unit: "ms")
        // Signed
        case 0x81: return Scaling(factor: 1, offset: 0, unit: "")
        case 0x82: return Scaling(factor: 0.1, offset: 0, unit: "")
        case 0x83: return Scaling(factor: 0.01, offset: 0, unit: "")
        case 0x84: return Scaling(factor: 0.001, offset: 0, unit: "")
        case 0x85: return Scaling(factor: 0.0000305, offset: 0, unit: "")
        case 0x86: return Scaling(factor: 0.000305, offset: 0, unit: "")
        case 0x8A: return Scaling(factor: 0.000122, offset: 0, unit: "V")
        case 0x8B: return Scaling(factor: 0.001, offset: 0, unit: "V")
        case 0x8C: return Scaling(factor: 0.01, offset: 0, unit: "V")
        case 0x8D: return Scaling(factor: 0.00390625, offset: 0, unit: "mA")
        case 0x8E: return Scaling(factor: 0.001, offset: 0, unit: "A")
        case 0x90: return Scaling(factor: 1, offset: 0, unit: "ms")
        case 0x96: return Scaling(factor: 0.1, offset: 0, unit: "°C")
        case 0x9C: return Scaling(factor: 0.01, offset: 0, unit: "°")
        case 0x9D: return Scaling(factor: 0.5, offset: 0, unit: "°")
        case 0xAF: return Scaling(factor: 0.01, offset: 0, unit: "%")
        case 0xB0: return Scaling(factor: 0.003052, offset: 0, unit: "%")
        case 0xFC: return Scaling(factor: 0.01, offset: 0, unit: "kPa")
        case 0xFD: return Scaling(factor: 0.001, offset: 0, unit: "kPa")
        case 0xFE: return Scaling(factor: 0.25, offset: 0, unit: "Pa")
        default: return Scaling(factor: 1, offset: 0, unit: "(raw)")
        }
    }
}

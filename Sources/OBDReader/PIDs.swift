import Foundation

enum UnitKind {
    case temperature, speed, distance, pressure, percent, rpm, volts, gramsPerSec,
         seconds, degrees, litersPerHour, ratio, count, milliamps, torque, none,
         hours, gearRatio, pascal, mgPerStroke
}

enum UnitSystem: String, CaseIterable, Identifiable {
    case us = "US (°F, mph, psi)"
    case metric = "Metric (°C, km/h, kPa)"
    var id: String { rawValue }
}

extension UnitKind {
    /// Convert a metric value into the chosen unit system and return (value, unit label).
    func present(_ v: Double, _ units: UnitSystem) -> (Double, String) {
        switch (self, units) {
        case (.temperature, .us): return (v * 9 / 5 + 32, "°F")
        case (.temperature, .metric): return (v, "°C")
        case (.speed, .us): return (v * 0.621371, "mph")
        case (.speed, .metric): return (v, "km/h")
        case (.distance, .us): return (v * 0.621371, "mi")
        case (.distance, .metric): return (v, "km")
        case (.pressure, .us): return (v * 0.145038, "psi")
        case (.pressure, .metric): return (v, "kPa")
        case (.litersPerHour, .us): return (v * 0.264172, "gal/h")
        case (.litersPerHour, .metric): return (v, "L/h")
        case (.torque, .us): return (v * 0.737562, "lb·ft")
        case (.torque, .metric): return (v, "N·m")
        case (.percent, _): return (v, "%")
        case (.rpm, _): return (v, "rpm")
        case (.volts, _): return (v, "V")
        case (.gramsPerSec, _): return (v, "g/s")
        case (.seconds, _): return (v, "s")
        case (.degrees, _): return (v, "°")
        case (.ratio, _): return (v, "λ")
        case (.milliamps, _): return (v, "mA")
        case (.hours, _): return (v, "h")
        case (.gearRatio, _): return (v, ":1")
        case (.pascal, _): return (v, "Pa")
        case (.mgPerStroke, _): return (v, "mg/stroke")
        case (.count, _), (.none, _): return (v, "")
        }
    }

    func format(_ v: Double, _ units: UnitSystem) -> String {
        let (x, unit) = present(v, units)
        let digits: Int
        switch self {
        case .rpm, .count, .seconds, .none: digits = 0
        case .volts, .ratio: digits = 2
        case .gearRatio: digits = 3
        default: digits = abs(x) < 100 ? 1 : 0
        }
        return String(format: "%.\(digits)f", x) + (unit.isEmpty ? "" : " \(unit)")
    }
}

/// One reading inside a multi-sensor PID (e.g. turbo A and turbo B speed in PID 0x74).
struct PIDChannel: Identifiable {
    let key: String                      // stable id, e.g. "74.A"
    let name: String
    let kind: UnitKind
    let decode: ([UInt8]) -> Double?     // nil when the car marks this sensor as not fitted
    var id: String { key }
}

struct PIDDef: Identifiable {
    let pid: UInt8
    let name: String
    let kind: UnitKind
    let bytes: Int
    let decode: ([UInt8]) -> Double
    /// Extra readings packed into the same PID (turbo, exhaust temps…). Empty for simple PIDs.
    var channels: [PIDChannel] = []
    /// False for status/enum PIDs and multi-sensor PIDs, which have their own pages.
    var onDashboard = true
    var id: UInt8 { pid }

    func present(_ v: Double, _ units: UnitSystem) -> (Double, String) { kind.present(v, units) }
    func format(_ v: Double, _ units: UnitSystem) -> String { kind.format(v, units) }
}

/// Standard SAE J1979 Mode 01 PIDs (the ones every OBD-II car may expose).
enum PIDs {
    private static func a(_ b: [UInt8]) -> Double { Double(b[0]) }
    private static func ab(_ b: [UInt8]) -> Double { Double(Int(b[0]) * 256 + Int(b[1])) }
    private static func trim(_ b: [UInt8]) -> Double { (Double(b[0]) - 128) * 100 / 128 }
    private static func pct(_ b: [UInt8]) -> Double { Double(b[0]) * 100 / 255 }
    private static func temp(_ b: [UInt8]) -> Double { Double(b[0]) - 40 }
    /// Big-endian 16-bit word starting at byte i.
    private static func w(_ b: [UInt8], _ i: Int) -> Double { Double(Int(b[i]) << 8 | Int(b[i + 1])) }
    /// Big-endian 32-bit word from the first four bytes.
    private static func u32(_ b: [UInt8]) -> Double {
        let hi: Int = Int(b[0]) << 24 | Int(b[1]) << 16
        let lo: Int = Int(b[2]) << 8 | Int(b[3])
        return Double(hi | lo)
    }
    /// Support bit `bit` in the first data byte of a multi-sensor PID.
    private static func has(_ b: [UInt8], _ bit: Int) -> Bool { b[0] & UInt8(1 << bit) != 0 }

    /// Build a multi-sensor PIDDef whose headline value is the first fitted channel.
    private static func multi(_ pid: UInt8, _ name: String, _ kind: UnitKind, bytes: Int,
                              _ channels: [PIDChannel]) -> PIDDef {
        PIDDef(pid: pid, name: name, kind: kind, bytes: bytes,
               decode: { b in channels.lazy.compactMap { $0.decode(b) }.first ?? .nan },
               channels: channels, onDashboard: false)
    }

    private static func turboTemps(_ pid: UInt8, _ turbo: String) -> PIDDef {
        let k = String(format: "%02X", Int(pid))
        return PIDs.multi(pid, "Turbo \(turbo) temperatures", .temperature, bytes: 7, [
            PIDChannel(key: "\(k).CI", name: "Turbo \(turbo) compressor inlet", kind: .temperature,
                       decode: { b in PIDs.has(b, 0) ? Double(b[1]) - 40 : nil }),
            PIDChannel(key: "\(k).CO", name: "Turbo \(turbo) compressor outlet", kind: .temperature,
                       decode: { b in PIDs.has(b, 1) ? Double(b[2]) - 40 : nil }),
            PIDChannel(key: "\(k).TI", name: "Turbo \(turbo) turbine inlet", kind: .temperature,
                       decode: { b in PIDs.has(b, 2) ? PIDs.w(b, 3) / 10 - 40 : nil }),
            PIDChannel(key: "\(k).TO", name: "Turbo \(turbo) turbine outlet", kind: .temperature,
                       decode: { b in PIDs.has(b, 3) ? PIDs.w(b, 5) / 10 - 40 : nil }),
        ])
    }

    private static func egt(_ pid: UInt8, bank: Int) -> PIDDef {
        let k = String(format: "%02X", Int(pid))
        let ch = (0..<4).map { i in
            PIDChannel(key: "\(k).\(i + 1)", name: "Exhaust temp bank \(bank) sensor \(i + 1)", kind: .temperature,
                       decode: { b in PIDs.has(b, i) ? PIDs.w(b, 1 + i * 2) / 10 - 40 : nil })
        }
        return PIDs.multi(pid, "Exhaust gas temp bank \(bank)", .temperature, bytes: 9, ch)
    }

    static let all: [PIDDef] = {
        var list: [PIDDef] = [
            PIDDef(pid: 0x03, name: "Fuel system status", kind: .none, bytes: 2, decode: PIDs.a, onDashboard: false),
            PIDDef(pid: 0x04, name: "Engine load", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x05, name: "Coolant temperature", kind: .temperature, bytes: 1, decode: PIDs.temp),
            PIDDef(pid: 0x06, name: "Short-term fuel trim B1", kind: .percent, bytes: 1, decode: PIDs.trim),
            PIDDef(pid: 0x07, name: "Long-term fuel trim B1", kind: .percent, bytes: 1, decode: PIDs.trim),
            PIDDef(pid: 0x08, name: "Short-term fuel trim B2", kind: .percent, bytes: 1, decode: PIDs.trim),
            PIDDef(pid: 0x09, name: "Long-term fuel trim B2", kind: .percent, bytes: 1, decode: PIDs.trim),
            PIDDef(pid: 0x0A, name: "Fuel pressure", kind: .pressure, bytes: 1, decode: { PIDs.a($0) * 3 }),
            PIDDef(pid: 0x0B, name: "Intake manifold pressure", kind: .pressure, bytes: 1, decode: PIDs.a),
            PIDDef(pid: 0x0C, name: "Engine RPM", kind: .rpm, bytes: 2, decode: { PIDs.ab($0) / 4 }),
            PIDDef(pid: 0x0D, name: "Vehicle speed", kind: .speed, bytes: 1, decode: PIDs.a),
            PIDDef(pid: 0x0E, name: "Timing advance", kind: .degrees, bytes: 1, decode: { PIDs.a($0) / 2 - 64 }),
            PIDDef(pid: 0x0F, name: "Intake air temperature", kind: .temperature, bytes: 1, decode: PIDs.temp),
            PIDDef(pid: 0x10, name: "Mass air flow", kind: .gramsPerSec, bytes: 2, decode: { PIDs.ab($0) / 100 }),
            PIDDef(pid: 0x11, name: "Throttle position", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x1F, name: "Run time since start", kind: .seconds, bytes: 2, decode: PIDs.ab),
            PIDDef(pid: 0x21, name: "Distance with MIL on", kind: .distance, bytes: 2, decode: PIDs.ab),
            PIDDef(pid: 0x22, name: "Fuel rail pressure (rel.)", kind: .pressure, bytes: 2, decode: { PIDs.ab($0) * 0.079 }),
            PIDDef(pid: 0x23, name: "Fuel rail pressure", kind: .pressure, bytes: 2, decode: { PIDs.ab($0) * 10 }),
            PIDDef(pid: 0x2C, name: "Commanded EGR", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x2E, name: "Commanded EVAP purge", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x2F, name: "Fuel level", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x30, name: "Warm-ups since codes cleared", kind: .count, bytes: 1, decode: PIDs.a),
            PIDDef(pid: 0x31, name: "Distance since codes cleared", kind: .distance, bytes: 2, decode: PIDs.ab),
            PIDDef(pid: 0x33, name: "Barometric pressure", kind: .pressure, bytes: 1, decode: PIDs.a),
            PIDDef(pid: 0x3C, name: "Catalyst temp B1S1", kind: .temperature, bytes: 2, decode: { PIDs.ab($0) / 10 - 40 }),
            PIDDef(pid: 0x3D, name: "Catalyst temp B2S1", kind: .temperature, bytes: 2, decode: { PIDs.ab($0) / 10 - 40 }),
            PIDDef(pid: 0x3E, name: "Catalyst temp B1S2", kind: .temperature, bytes: 2, decode: { PIDs.ab($0) / 10 - 40 }),
            PIDDef(pid: 0x3F, name: "Catalyst temp B2S2", kind: .temperature, bytes: 2, decode: { PIDs.ab($0) / 10 - 40 }),
            PIDDef(pid: 0x42, name: "Control module voltage", kind: .volts, bytes: 2, decode: { PIDs.ab($0) / 1000 }),
            PIDDef(pid: 0x43, name: "Absolute load", kind: .percent, bytes: 2, decode: { PIDs.ab($0) * 100 / 255 }),
            PIDDef(pid: 0x44, name: "Commanded air-fuel ratio", kind: .ratio, bytes: 2, decode: { PIDs.ab($0) * 2 / 65536 }),
            PIDDef(pid: 0x45, name: "Relative throttle", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x46, name: "Ambient air temperature", kind: .temperature, bytes: 1, decode: PIDs.temp),
            PIDDef(pid: 0x47, name: "Absolute throttle B", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x49, name: "Accelerator pedal D", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x4A, name: "Accelerator pedal E", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x4C, name: "Commanded throttle", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x4D, name: "Time run with MIL on (min)", kind: .count, bytes: 2, decode: PIDs.ab),
            PIDDef(pid: 0x4E, name: "Time since codes cleared (min)", kind: .count, bytes: 2, decode: PIDs.ab),
            PIDDef(pid: 0x51, name: "Fuel type", kind: .none, bytes: 1, decode: PIDs.a, onDashboard: false),
            PIDDef(pid: 0x52, name: "Ethanol fuel %", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x5A, name: "Relative pedal position", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x5C, name: "Engine oil temperature", kind: .temperature, bytes: 1, decode: PIDs.temp),
            PIDDef(pid: 0x5D, name: "Fuel injection timing", kind: .degrees, bytes: 2, decode: { PIDs.ab($0) / 128 - 210 }),
            PIDDef(pid: 0x5E, name: "Engine fuel rate", kind: .litersPerHour, bytes: 2, decode: { PIDs.ab($0) / 20 }),
            PIDDef(pid: 0x61, name: "Driver-demand torque", kind: .percent, bytes: 1, decode: { PIDs.a($0) - 125 }),
            PIDDef(pid: 0x62, name: "Actual engine torque", kind: .percent, bytes: 1, decode: { PIDs.a($0) - 125 }),
            PIDDef(pid: 0x63, name: "Engine reference torque", kind: .torque, bytes: 2, decode: PIDs.ab, onDashboard: false),
            PIDDef(pid: 0xA6, name: "Odometer", kind: .distance, bytes: 4,
                   decode: { PIDs.u32($0) / 10 },
                   onDashboard: false),
            // Remaining standard readings (SAE J1979 Service 01)
            PIDDef(pid: 0x12, name: "Commanded secondary air", kind: .none, bytes: 1, decode: PIDs.a, onDashboard: false),
            PIDDef(pid: 0x1C, name: "OBD standard", kind: .none, bytes: 1, decode: PIDs.a, onDashboard: false),
            PIDDef(pid: 0x1E, name: "PTO (power take-off) active", kind: .none, bytes: 1,
                   decode: { Double($0[0] & 1) }, onDashboard: false),
            PIDDef(pid: 0x2D, name: "EGR error", kind: .percent, bytes: 1, decode: PIDs.trim),
            PIDDef(pid: 0x32, name: "Evap vapor pressure", kind: .pascal, bytes: 2,
                   decode: { b in Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 4 }),
            PIDDef(pid: 0x48, name: "Absolute throttle C", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x4B, name: "Accelerator pedal F", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDDef(pid: 0x53, name: "Evap vapor pressure (absolute)", kind: .pressure, bytes: 2, decode: { PIDs.ab($0) / 200 }),
            PIDDef(pid: 0x54, name: "Evap vapor pressure (wide range)", kind: .pascal, bytes: 2,
                   decode: { PIDs.ab($0) - 32767 }),   // (256A+B) − 32767 Pa: Wikipedia + CSS Electronics OBD2 DBC
            PIDDef(pid: 0x55, name: "Short-term rear O2 trim B1", kind: .percent, bytes: 2, decode: PIDs.trim),
            PIDDef(pid: 0x56, name: "Long-term rear O2 trim B1", kind: .percent, bytes: 2, decode: PIDs.trim),
            PIDDef(pid: 0x57, name: "Short-term rear O2 trim B2", kind: .percent, bytes: 2, decode: PIDs.trim),
            PIDDef(pid: 0x58, name: "Long-term rear O2 trim B2", kind: .percent, bytes: 2, decode: PIDs.trim),
            PIDDef(pid: 0x59, name: "Fuel rail pressure (absolute)", kind: .pressure, bytes: 2, decode: { PIDs.ab($0) * 10 }),
            PIDDef(pid: 0x5B, name: "Hybrid battery remaining life", kind: .percent, bytes: 1, decode: PIDs.pct),
            PIDs.multi(0x67, "Coolant temperature sensors", .temperature, bytes: 3, [
                PIDChannel(key: "67.1", name: "Coolant temperature sensor 1", kind: .temperature,
                           decode: { b in PIDs.has(b, 0) ? Double(b[1]) - 40 : nil }),
                PIDChannel(key: "67.2", name: "Coolant temperature sensor 2", kind: .temperature,
                           decode: { b in PIDs.has(b, 1) ? Double(b[2]) - 40 : nil }),
            ]),
            PIDDef(pid: 0x7F, name: "Engine run time (total)", kind: .hours, bytes: 13,
                   decode: { b in PIDs.u32(Array(b[1...4])) / 3600 },
                   onDashboard: false),
            PIDDef(pid: 0xA2, name: "Cylinder fuel rate", kind: .mgPerStroke, bytes: 2, decode: { PIDs.ab($0) / 32 }),
            PIDDef(pid: 0xA4, name: "Transmission gear ratio", kind: .gearRatio, bytes: 4,
                   decode: { b in b[0] & 0x02 != 0 ? PIDs.w(b, 2) / 1000 : .nan }),
            PIDDef(pid: 0xA9, name: "ABS disable switch", kind: .none, bytes: 4,
                   decode: { b in b[0] & 1 != 0 ? Double(b[1] & 1) : .nan }, onDashboard: false),
            PIDs.multi(0x6F, "Turbo compressor inlet pressure", .pressure, bytes: 3, [
                PIDChannel(key: "6F.A", name: "Compressor inlet pressure A", kind: .pressure,
                           decode: { b in PIDs.has(b, 0) ? Double(b[1]) : nil }),
                PIDChannel(key: "6F.B", name: "Compressor inlet pressure B", kind: .pressure,
                           decode: { b in PIDs.has(b, 1) ? Double(b[2]) : nil }),
            ]),
            PIDs.multi(0x74, "Turbo speed", .rpm, bytes: 5, [
                PIDChannel(key: "74.A", name: "Turbo A speed", kind: .rpm,
                           decode: { b in PIDs.has(b, 0) ? PIDs.w(b, 1) * 10 : nil }),
                PIDChannel(key: "74.B", name: "Turbo B speed", kind: .rpm,
                           decode: { b in PIDs.has(b, 1) ? PIDs.w(b, 3) * 10 : nil }),
            ]),
            // Layouts per SAE J1979 as published by DashLogic (docs/technical/obdii_pids);
            // byte counts match Wikipedia's OBD-II PID table.
            PIDs.multi(0x70, "Boost pressure control", .pressure, bytes: 10, [
                PIDChannel(key: "70.CA", name: "Commanded boost A", kind: .pressure,
                           decode: { b in PIDs.has(b, 0) ? PIDs.w(b, 1) / 32 : nil }),
                PIDChannel(key: "70.A", name: "Boost pressure A", kind: .pressure,
                           decode: { b in PIDs.has(b, 1) ? PIDs.w(b, 3) / 32 : nil }),
                PIDChannel(key: "70.CB", name: "Commanded boost B", kind: .pressure,
                           decode: { b in PIDs.has(b, 3) ? PIDs.w(b, 5) / 32 : nil }),
                PIDChannel(key: "70.B", name: "Boost pressure B", kind: .pressure,
                           decode: { b in PIDs.has(b, 4) ? PIDs.w(b, 7) / 32 : nil }),
            ]),
            PIDs.multi(0x72, "Wastegate control", .percent, bytes: 5, [
                PIDChannel(key: "72.CA", name: "Commanded wastegate A", kind: .percent,
                           decode: { b in PIDs.has(b, 0) ? Double(b[1]) / 2.55 : nil }),
                PIDChannel(key: "72.A", name: "Wastegate A position", kind: .percent,
                           decode: { b in PIDs.has(b, 1) ? Double(b[2]) / 2.55 : nil }),
                PIDChannel(key: "72.CB", name: "Commanded wastegate B", kind: .percent,
                           decode: { b in PIDs.has(b, 2) ? Double(b[3]) / 2.55 : nil }),
                PIDChannel(key: "72.B", name: "Wastegate B position", kind: .percent,
                           decode: { b in PIDs.has(b, 3) ? Double(b[4]) / 2.55 : nil }),
            ]),
            PIDs.multi(0x73, "Exhaust pressure", .pressure, bytes: 5, [
                PIDChannel(key: "73.1", name: "Exhaust pressure bank 1", kind: .pressure,
                           decode: { b in PIDs.has(b, 0) ? PIDs.w(b, 1) / 100 : nil }),
                PIDChannel(key: "73.2", name: "Exhaust pressure bank 2", kind: .pressure,
                           decode: { b in PIDs.has(b, 1) ? PIDs.w(b, 3) / 100 : nil }),
            ]),
            PIDs.multi(0x77, "Charge air cooler temperature", .temperature, bytes: 5, [
                PIDChannel(key: "77.11", name: "Charge air cooler B1S1", kind: .temperature,
                           decode: { b in PIDs.has(b, 0) ? Double(b[1]) - 40 : nil }),
                PIDChannel(key: "77.12", name: "Charge air cooler B1S2", kind: .temperature,
                           decode: { b in PIDs.has(b, 1) ? Double(b[2]) - 40 : nil }),
                PIDChannel(key: "77.21", name: "Charge air cooler B2S1", kind: .temperature,
                           decode: { b in PIDs.has(b, 2) ? Double(b[3]) - 40 : nil }),
                PIDChannel(key: "77.22", name: "Charge air cooler B2S2", kind: .temperature,
                           decode: { b in PIDs.has(b, 3) ? Double(b[4]) - 40 : nil }),
            ]),
            PIDs.turboTemps(0x75, "A"),
            PIDs.turboTemps(0x76, "B"),
            // Engine percent torque data: idle and points 1–4, each byte − 125 % (Wikipedia OBD-II PIDs).
            PIDs.multi(0x64, "Engine percent torque points", .percent, bytes: 5, [
                PIDChannel(key: "64.I", name: "Torque at idle", kind: .percent, decode: { b in Double(b[0]) - 125 }),
                PIDChannel(key: "64.1", name: "Torque point 1", kind: .percent, decode: { b in Double(b[1]) - 125 }),
                PIDChannel(key: "64.2", name: "Torque point 2", kind: .percent, decode: { b in Double(b[2]) - 125 }),
                PIDChannel(key: "64.3", name: "Torque point 3", kind: .percent, decode: { b in Double(b[3]) - 125 }),
                PIDChannel(key: "64.4", name: "Torque point 4", kind: .percent, decode: { b in Double(b[4]) - 125 }),
            ]),
            // Mass air flow sensors A/B: support bits, then (256B+C)/32 and (256D+E)/32 g/s.
            PIDs.multi(0x66, "Mass air flow sensors", .gramsPerSec, bytes: 5, [
                PIDChannel(key: "66.A", name: "MAF sensor A", kind: .gramsPerSec,
                           decode: { b in PIDs.has(b, 0) ? PIDs.w(b, 1) / 32 : nil }),
                PIDChannel(key: "66.B", name: "MAF sensor B", kind: .gramsPerSec,
                           decode: { b in PIDs.has(b, 1) ? PIDs.w(b, 3) / 32 : nil }),
            ]),
            // Intake air temperature sensors 1/2: support bits, then B − 40 and C − 40 °C.
            PIDs.multi(0x68, "Intake air temperature sensors", .temperature, bytes: 3, [
                PIDChannel(key: "68.1", name: "Intake air temp sensor 1", kind: .temperature,
                           decode: { b in PIDs.has(b, 0) ? Double(b[1]) - 40 : nil }),
                PIDChannel(key: "68.2", name: "Intake air temp sensor 2", kind: .temperature,
                           decode: { b in PIDs.has(b, 1) ? Double(b[2]) - 40 : nil }),
            ]),
            PIDDef(pid: 0x8E, name: "Engine friction torque", kind: .percent, bytes: 1, decode: { b in Double(b[0]) - 125 }),
            // Commanded DEF dosing: B / 2 % when bit A0 says it's supported.
            PIDDef(pid: 0xA5, name: "Commanded DEF dosing", kind: .percent, bytes: 4,
                   decode: { b in b[0] & 0x01 != 0 ? Double(b[1]) / 2 : .nan }),
            PIDs.egt(0x78, bank: 1),
            PIDs.egt(0x79, bank: 2),
            // Diesel particulate filter temperatures: support byte then four 16-bit temps,
            // (256A+B)/10 − 40 °C (Wikipedia OBD-II PIDs); layout assumed like 78/79 — verify on a car.
            PIDs.multi(0x7C, "Particulate filter temperature", .temperature, bytes: 9, [
                PIDChannel(key: "7C.1I", name: "DPF bank 1 inlet", kind: .temperature,
                           decode: { b in PIDs.has(b, 0) ? PIDs.w(b, 1) / 10 - 40 : nil }),
                PIDChannel(key: "7C.1O", name: "DPF bank 1 outlet", kind: .temperature,
                           decode: { b in PIDs.has(b, 1) ? PIDs.w(b, 3) / 10 - 40 : nil }),
                PIDChannel(key: "7C.2I", name: "DPF bank 2 inlet", kind: .temperature,
                           decode: { b in PIDs.has(b, 2) ? PIDs.w(b, 5) / 10 - 40 : nil }),
                PIDChannel(key: "7C.2O", name: "DPF bank 2 outlet", kind: .temperature,
                           decode: { b in PIDs.has(b, 3) ? PIDs.w(b, 7) / 10 - 40 : nil }),
            ]),
            // NOx reagent (DEF/AdBlue) system: byte F = tank level, 100/255·F % (Wikipedia OBD-II PIDs).
            PIDDef(pid: 0x85, name: "DEF / AdBlue tank level", kind: .percent, bytes: 10,
                   decode: { b in Double(b[5]) * 100 / 255 }),
            PIDs.multi(0x87, "Intake manifold pressure (high range)", .pressure, bytes: 5, [
                PIDChannel(key: "87.A", name: "Manifold pressure A", kind: .pressure,
                           decode: { b in PIDs.has(b, 0) ? PIDs.w(b, 1) / 32 : nil }),
                PIDChannel(key: "87.B", name: "Manifold pressure B", kind: .pressure,
                           decode: { b in PIDs.has(b, 1) ? PIDs.w(b, 3) / 32 : nil }),
            ]),
        ]
        let sensors = ["B1S1", "B1S2", "B1S3", "B1S4", "B2S1", "B2S2", "B2S3", "B2S4"]
        for i in 0..<8 {
            // Narrowband O2 voltages (0x14–0x1B)
            // Formulas: SAE J1979 as given by Wikipedia "OBD-II PIDs" and the CSS Electronics OBD2
            // DBC v4.3 (A/200 V; 100/128·B − 100 %, B = FF means "not used for trim";
            // 2/65536·AB λ; 8/65536·CD V; CD/256 − 128 mA).
            let n = sensors[i]
            let k1 = String(format: "%02X", 0x14 + i), k2 = String(format: "%02X", 0x24 + i), k3 = String(format: "%02X", 0x34 + i)
            list.append(PIDDef(pid: UInt8(0x14 + i), name: "O2 sensor \(n)",
                               kind: .volts, bytes: 2, decode: { PIDs.a($0) / 200 },
                               channels: [
                                PIDChannel(key: "\(k1).V", name: "O2 \(n) voltage", kind: .volts, decode: { b in Double(b[0]) / 200 }),
                                PIDChannel(key: "\(k1).T", name: "O2 \(n) short-term trim", kind: .percent,
                                           decode: { b in b[1] == 0xFF ? nil : Double(b[1]) * 100 / 128 - 100 }),
                               ], onDashboard: true))
            list.append(PIDDef(pid: UInt8(0x24 + i), name: "Wideband O2 \(n) λ",
                               kind: .ratio, bytes: 4, decode: { PIDs.ab($0) * 2 / 65536 },
                               channels: [
                                PIDChannel(key: "\(k2).L", name: "Wideband O2 \(n) λ", kind: .ratio, decode: { b in PIDs.ab(b) * 2 / 65536 }),
                                PIDChannel(key: "\(k2).V", name: "Wideband O2 \(n) voltage", kind: .volts, decode: { b in PIDs.w(b, 2) * 8 / 65536 }),
                               ], onDashboard: true))
            list.append(PIDDef(pid: UInt8(0x34 + i), name: "Wideband O2 \(n) λ (current type)",
                               kind: .ratio, bytes: 4, decode: { PIDs.ab($0) * 2 / 65536 },
                               channels: [
                                PIDChannel(key: "\(k3).L", name: "Wideband O2 \(n) λ", kind: .ratio, decode: { b in PIDs.ab(b) * 2 / 65536 }),
                                PIDChannel(key: "\(k3).I", name: "Wideband O2 \(n) current", kind: .milliamps, decode: { b in PIDs.w(b, 2) / 256 - 128 }),
                               ], onDashboard: true))
        }
        return list.sorted { $0.pid < $1.pid }
    }()

    static func def(_ pid: UInt8) -> PIDDef? { all.first { $0.pid == pid } }

    /// Every channel key → (owning PID, channel), for the multi-sensor pages.
    static let channels: [(pid: UInt8, channel: PIDChannel)] =
        all.flatMap { d in d.channels.map { (pid: d.pid, channel: $0) } }

    /// Turbo, torque and exhaust PIDs shown on the Turbo & Torque page.
    static let performancePIDs: [UInt8] = [0x61, 0x62, 0x63, 0x6F, 0x70, 0x72, 0x73, 0x77, 0x74, 0x75, 0x76, 0x78, 0x79, 0x7C, 0x87, 0x0B, 0x33, 0x5D]

    /// PIDs most useful on a dashboard, in display order.
    static let dashboardDefaults: [UInt8] = [0x0C, 0x0D, 0x05, 0x04, 0x11, 0x0B, 0x10, 0x0F,
                                             0x06, 0x07, 0x08, 0x09, 0x42, 0x5C, 0x2F, 0x0E]

    /// Decode a "supported PIDs" bitmap (response to 0100/0120/0140/…).
    static func supported(base: UInt8, bitmap: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for (byteIndex, byte) in bitmap.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                out.append(base &+ UInt8(byteIndex * 8 + bit + 1))
            }
        }
        return out
    }

    /// Fuel system status (PID 03, byte A) → is the engine using the O2 sensors (closed loop)?
    /// nil = unknown/not reported. 2 = closed loop, 16 = closed loop with a feedback fault.
    static func closedLoop(_ status: Double?) -> Bool? {
        guard let s = status, s > 0 else { return nil }
        let v = Int(s)
        return v == 2 || v == 16
    }

    static func fuelSystemText(_ status: Double?) -> String {
        switch Int(status ?? 0) {
        case 1: return "Open loop — engine still warming up"
        case 2: return "Closed loop — using O2 sensors"
        case 4: return "Open loop — heavy load or deceleration"
        case 8: return "Open loop — because of a system fault"
        case 16: return "Closed loop — with an O2 feedback fault"
        default: return "Not reported"
        }
    }

    /// PID 1C — which OBD standard the car was built to (SAE J1979 table).
    static func obdStandardText(_ v: Double?) -> String? {
        guard let v else { return nil }
        let names = [1: "OBD-II (CARB)", 2: "OBD (EPA)", 3: "OBD and OBD-II", 4: "OBD-I", 5: "Not OBD compliant",
                     6: "EOBD (Europe)", 7: "EOBD and OBD-II", 8: "EOBD and OBD", 9: "EOBD, OBD and OBD-II",
                     10: "JOBD (Japan)", 11: "JOBD and OBD-II", 12: "JOBD and EOBD", 13: "JOBD, EOBD and OBD-II",
                     14: "OBD, EOBD and KOBD", 15: "OBD, OBD-II, EOBD and KOBD", 17: "Engine Manufacturer Diagnostics (EMD)",
                     18: "EMD+", 19: "Heavy-duty OBD (child/partial)", 20: "Heavy-duty OBD", 21: "World-wide harmonised OBD",
                     23: "HD Euro OBD stage I", 24: "HD Euro OBD stage I with NOx control", 25: "HD Euro OBD stage II",
                     26: "HD Euro OBD stage II with NOx control", 27: "Heavy-duty ZEV", 28: "Brazil OBD phase 1",
                     29: "Brazil OBD phase 2", 30: "Korean OBD", 31: "India OBD I", 32: "India OBD II",
                     33: "HD Euro OBD stage VI", 34: "OBD, OBD-II and HD OBD", 35: "Brazil OBD phase 3"]
        return names[Int(v)] ?? "Code \(Int(v))"
    }

    /// PID 12 — commanded secondary air.
    static func secondaryAirText(_ v: Double?) -> String? {
        guard let v else { return nil }
        return [1: "Upstream", 2: "Downstream of catalytic converter", 4: "Outside air / off", 8: "Pump on for diagnostics"][Int(v)]
    }

    static func fuelTypeText(_ v: Double?) -> String? {
        guard let v else { return nil }
        let names = [1: "Gasoline", 2: "Methanol", 3: "Ethanol", 4: "Diesel", 5: "LPG", 6: "CNG", 7: "Propane",
                     8: "Electric", 9: "Bifuel gasoline", 16: "Hybrid gasoline", 17: "Hybrid ethanol",
                     18: "Hybrid diesel", 19: "Hybrid electric", 20: "Hybrid mixed fuel"]
        return names[Int(v)]
    }

    static func isDieselFuel(_ v: Double?) -> Bool? {
        guard let v else { return nil }
        return [4, 18].contains(Int(v))
    }
}

/// Mode 01 PID 01: MIL status and readiness monitors.
struct Readiness {
    struct Monitor: Identifiable {
        let name: String
        let complete: Bool
        var id: String { name }
    }

    let milOn: Bool
    let dtcCount: Int
    let isDiesel: Bool
    let monitors: [Monitor]

    init?(_ d: [UInt8]) {
        guard d.count >= 4 else { return nil }
        let (a, b, c, dd) = (d[0], d[1], d[2], d[3])
        milOn = a & 0x80 != 0
        dtcCount = Int(a & 0x7F)
        isDiesel = b & 0x08 != 0

        var m: [Monitor] = []
        let common = ["Misfire", "Fuel system", "Comprehensive components"]
        for (i, name) in common.enumerated() where b & (1 << UInt8(i)) != 0 {
            m.append(Monitor(name: name, complete: b & (1 << UInt8(i + 4)) == 0))
        }
        let names = isDiesel
            ? ["NMHC catalyst", "NOx/SCR aftertreatment", "—", "Boost pressure", "—",
               "Exhaust gas sensor", "PM filter", "EGR/VVT"]
            : ["Catalyst", "Heated catalyst", "Evaporative system", "Secondary air",
               "A/C refrigerant", "Oxygen sensor", "Oxygen sensor heater", "EGR/VVT"]
        for (i, name) in names.enumerated() where name != "—" && c & (1 << UInt8(i)) != 0 {
            m.append(Monitor(name: name, complete: dd & (1 << UInt8(i)) == 0))
        }
        monitors = m
    }

    var incompleteCount: Int { monitors.filter { !$0.complete }.count }

    /// Combine the 0101 answers from every control unit that responded.
    /// A monitor counts as not-ready if any ECU that supports it reports it incomplete;
    /// the check-engine light is on if any ECU commands it, and the code count is the sum.
    /// This matters for a smog check, which looks at every module, not just the engine.
    static func combined(_ frames: [[UInt8]], pid: UInt8 = 0x01) -> Readiness? {
        let payloads = frames.compactMap { f -> [UInt8]? in
            f.count >= 6 && f[0] == 0x41 && f[1] == pid ? Array(f[2...5]) : nil
        }
        guard !payloads.isEmpty else { return nil }
        var merged: [UInt8] = [0, 0, 0, 0]
        var dtcTotal = 0
        for p in payloads {
            if p[0] & 0x80 != 0 { merged[0] |= 0x80 }
            dtcTotal += Int(p[0] & 0x7F)
            // Support bits and "not complete" bits sit in different bit positions within
            // bytes 1–3, so a bitwise OR across ECUs combines both correctly.
            merged[1] |= p[1]; merged[2] |= p[2]; merged[3] |= p[3]
        }
        merged[0] |= UInt8(min(dtcTotal, 0x7F))
        return Readiness(merged)
    }
}

extension PIDDef {
    /// Inverse of `present`: a value typed in the chosen unit system → metric (for alert limits).
    func toMetric(_ x: Double, _ units: UnitSystem) -> Double {
        guard units == .us else { return x }
        switch kind {
        case .temperature: return (x - 32) * 5 / 9
        case .speed, .distance: return x / 0.621371
        case .pressure: return x / 0.145038
        case .litersPerHour: return x / 0.264172
        case .torque: return x / 0.737562
        default: return x
        }
    }

    func unitLabel(_ units: UnitSystem) -> String { present(0, units).1 }
}


/// Maximum values a car reports for some sensors (PID 4F: λ, O2 voltage, O2 current, MAP; PID 50: MAF).
/// The app decodes those sensors with the standard default ranges (λ 2, 8 V, 128 mA, 255 kPa,
/// 655.35 g/s). When a car reports different maxima we flag it rather than guess a new formula.
struct SensorRanges {
    var maxLambda: Double?
    var maxO2Volts: Double?
    var maxO2mA: Double?
    var maxMAPkPa: Double?
    var maxMAF: Double?

    var isEmpty: Bool { maxLambda == nil && maxO2Volts == nil && maxO2mA == nil && maxMAPkPa == nil && maxMAF == nil }

    /// Plain-English notes for any range that differs from the default the app assumes.
    var warnings: [String] {
        var w: [String] = []
        if let v = maxLambda, v != 2 { w.append("Wideband O2 λ: car's maximum is \(VAGBlocks.format(v)), the app assumes 2 — wideband λ readings may be scaled differently.") }
        if let v = maxO2Volts, v != 8 { w.append("Wideband O2 voltage: car's maximum is \(VAGBlocks.format(v)) V, the app assumes 8 V.") }
        if let v = maxO2mA, v != 128 { w.append("Wideband O2 current: car's maximum is \(VAGBlocks.format(v)) mA, the app assumes 128 mA.") }
        if let v = maxMAPkPa, v > 255 { w.append("Manifold pressure: car's maximum is \(VAGBlocks.format(v)) kPa — the basic MAP reading tops out at 255 kPa; use the high-range boost reading (PID 87) if available.") }
        if let v = maxMAF, v > 0, abs(v - 655.35) > 10 { w.append("Mass air flow: car's maximum is \(VAGBlocks.format(v)) g/s, the app assumes 655.35 g/s — MAF readings may be scaled differently.") }
        return w
    }
}

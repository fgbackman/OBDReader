import Foundation

// OBDb importer: turns an OBDb "signalset" (github.com/OBDb/<Make-Model>/signalsets/v3/default.json)
// into Custom Readings. OBDb is a community database of manufacturer readings, licensed
// CC BY-SA 4.0 — imported readings keep a source line crediting OBDb and the model's repository.
//
// Format (read from real signalsets): each command has hdr (request address), optional rax
// (reply address), eax (extended address byte), pri (29-bit priority) and tst (tester address),
// cmd {"22": "1014"}, and signals whose fmt gives bix (bit index from the first data byte after the
// echoed identifier), len (bits), blsb (little-endian), sign, mul, div, add, unit, min, max, map.
// Only read services 01, 21 and 22 are imported.

struct BitField: Codable, Hashable {
    var bix: Int = 0
    var len: Int = 8
    var signed = false
    var littleEndian = false
    var mul: Double = 1
    var div: Double = 1
    var add: Double = 0
    var map: [String: String]?
    var nullMin: Double?        // values at or below this mean "not available"
    var nullMax: Double?        // values at or above this mean "not available"

    func value(_ bytes: [UInt8]) -> Double? {
        guard len > 0, len <= 64 else { return nil }
        var raw: UInt64 = 0
        if littleEndian && bix % 8 == 0 && len % 8 == 0 {
            let start = bix / 8, n = len / 8
            guard start + n <= bytes.count else { return nil }
            for k in (0..<n).reversed() { raw = raw << 8 | UInt64(bytes[start + k]) }
        } else {
            guard bix + len <= bytes.count * 8 else { return nil }
            for i in bix..<(bix + len) {
                let bit = (bytes[i / 8] >> (7 - UInt8(i % 8))) & 1
                raw = raw << 1 | UInt64(bit)
            }
        }
        var v: Double
        if signed && len < 64 && raw & (1 << UInt64(len - 1)) != 0 {
            v = Double(Int64(bitPattern: raw) - (Int64(1) << Int64(len)))
        } else {
            v = Double(raw)
        }
        v = v * mul / (div == 0 ? 1 : div) + add
        if let n = nullMax, v >= n { return nil }
        if let n = nullMin, v <= n { return nil }
        return v
    }

    var summary: String {
        var s = "bits \(bix)+\(len)"
        if signed { s += " signed" }
        if littleEndian { s += " LE" }
        if mul != 1 { s += " ×\(VAGBlocks.format(mul))" }
        if div != 1 { s += " ÷\(VAGBlocks.format(div))" }
        if add != 0 { s += " \(add > 0 ? "+" : "−")\(VAGBlocks.format(abs(add)))" }
        return s
    }
}

enum OBDb {
    static let licenseNote = "Readings from OBDb (github.com/OBDb), © OBDb contributors, CC BY-SA 4.0."

    static func isSignalset(_ data: Data) -> Bool {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return o["commands"] is [Any]
    }

    /// Repository name OBDb uses for a make and model, e.g. "Volkswagen-Jetta".
    static func repoName(make: String, model: String) -> String {
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces).split(separator: " ").joined(separator: "-")
        }
        var mk = clean(make)
        if mk.lowercased() == "vw" { mk = "Volkswagen" }
        if mk.lowercased() == "chevy" { mk = "Chevrolet" }
        if mk.lowercased() == "mercedes" { mk = "Mercedes-Benz" }
        return mk + "-" + clean(model)
    }

    static func url(repo: String) -> URL? {
        URL(string: "https://raw.githubusercontent.com/OBDb/\(repo)/main/signalsets/v3/default.json")
    }

    static let units: [String: String] = [
        "celsius": "°C", "fahrenheit": "°F", "percent": "%", "volts": "V", "millivolts": "mV", "amps": "A",
        "milliamps": "mA", "degrees": "°", "kilometersPerHour": "km/h", "milesPerHour": "mph", "rpm": "rpm",
        "kilometers": "km", "miles": "mi", "milliseconds": "ms", "seconds": "s", "minutes": "min", "hours": "h",
        "kilopascal": "kPa", "psi": "psi", "bars": "bar", "newtonMeters": "Nm", "millimeters": "mm",
        "centimeters": "cm", "meters": "m", "ampereHours": "Ah", "kilowattHours": "kWh", "kilowatts": "kW",
        "watts": "W", "liters": "l", "gallons": "gal", "gramsPerSecond": "g/s", "metersPerSecondSquared": "m/s²",
        "gravity": "g", "hertz": "Hz", "ohms": "Ω", "milliohms": "mΩ", "kiloohms": "kΩ", "megaohms": "MΩ",
        "radians": "rad", "litersPerHour": "l/h", "kilogramsPerHour": "kg/h", "metersPerSecond": "m/s",
        "gramsPerLiter": "g/l", "kelvin": "K", "milliampereHours": "mAh", "kilowattHoursPer100Kilometers": "kWh/100km", "kilowattHoursPer100Miles": "kWh/100mi",
    ]

    /// Parse a signalset. `modelYear` drops commands whose year filter excludes the car.
    static func load(_ data: Data, source: String, modelYear: Int?, is29Bit: Bool? = nil) -> [CustomPID] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = root["commands"] as? [[String: Any]] else { return [] }
        var out: [CustomPID] = []
        for c in commands {
            if let y = modelYear, let f = c["filter"] as? [String: Any], !yearMatches(y, f) { continue }
            guard let cmd = c["cmd"] as? [String: String], let first = cmd.first,
                  CustomPID.allowedServices.contains(first.key.uppercased()) else { continue }
            let svc = first.key, pid = first.value
            if c["din"] != nil { continue }                       // needs a diagnostic session this app doesn't open
            guard let header = headerSpec(c) else { continue }
            if let want = is29Bit, ModuleTarget(spec: header)?.is29Bit != want { continue }   // other bus
            let request = (svc + pid).uppercased()
            for sg in c["signals"] as? [[String: Any]] ?? [] {
                if sg["hidden"] as? Bool == true { continue }
                guard let fmt = sg["fmt"] as? [String: Any] else { continue }
                var bf = BitField()
                bf.bix = fmt["bix"] as? Int ?? 0
                bf.len = fmt["len"] as? Int ?? 8
                bf.signed = fmt["sign"] as? Bool ?? false
                bf.littleEndian = fmt["blsb"] as? Bool ?? false
                bf.mul = number(fmt["mul"]) ?? 1
                bf.div = number(fmt["div"]) ?? 1
                bf.add = number(fmt["add"]) ?? 0
                bf.nullMin = number(fmt["nullmin"])
                bf.nullMax = number(fmt["nullmax"])
                if let m = fmt["map"] as? [String: Any] {
                    var mm: [String: String] = [:]
                    for (k, v) in m { mm[k] = ((v as? [String: Any])?["description"] as? String) ?? "\(v)" }
                    bf.map = mm
                }
                let rawUnit = fmt["unit"] as? String ?? ""
                if bf.map == nil {
                    switch rawUnit {
                    case "offon", "onoff": bf.map = ["0": "Off", "1": "On"]
                    case "noyes", "yesno": bf.map = ["0": "No", "1": "Yes"]
                    default: break
                    }
                }
                let unit = units[rawUnit] ?? ""
                var name = sg["name"] as? String ?? (sg["id"] as? String ?? "Reading")
                if let path = sg["path"] as? String, !path.isEmpty { name = "\(path): \(name)" }
                var p = CustomPID(name: name, header: header, request: request, formula: bf.summary, unit: unit,
                                  minValue: number(fmt["min"]), maxValue: number(fmt["max"]), enabled: false)
                p.bits = bf
                p.source = source
                out.append(p)
            }
        }
        return out
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    /// OBDb filters: "years" lists exact years; "from"/"to" give a range. When "to" is earlier
    /// than "from" (e.g. to 2010, from 2025) it means "up to to, or from onward".
    private static func yearMatches(_ y: Int, _ f: [String: Any]) -> Bool {
        let years = f["years"] as? [Int]
        if years?.contains(y) == true { return true }
        let from = f["from"] as? Int, to = f["to"] as? Int
        switch (from, to) {
        case let (a?, b?): return a <= b ? (a...b).contains(y) : (y <= b || y >= a)
        case let (a?, nil): return y >= a
        case let (nil, b?): return y <= b
        default: return years == nil
        }
    }

    /// Our address spec ("713>77D", "6F1/12>612", "17FC0076>17FE0076") from an OBDb command.
    private static func headerSpec(_ c: [String: Any]) -> String? {
        guard let hdr = (c["hdr"] as? String)?.uppercased() else { return nil }
        let rax = (c["rax"] as? String)?.uppercased()
        let eax = (c["eax"] as? String)?.uppercased()
        if hdr.count == 3 {
            var s = hdr
            if let e = eax, e.count == 2 { s += "/" + e }
            if let r = rax, r.count == 3 { s += ">" + r }
            else if hdr == "6F1", let e = eax, e.count == 2 { s += ">6" + e }   // BMW replies on 600 + module
            return ModuleTarget(spec: s)?.spec
        }
        if hdr.count == 4 {                                  // 29-bit: priority + hdr + tester
            // Without pri/tst a custom reply ID can't be placed reliably — skip those.
            if let r = rax, r.count >= 6, c["pri"] == nil || c["tst"] == nil { return nil }
            let pri = (c["pri"] as? String)?.uppercased() ?? "18"
            let tst = (c["tst"] as? String)?.uppercased() ?? "F1"
            var s = pri + hdr + tst
            if let r = rax, r.count == 6 { s += ">" + pri + r } else if let r = rax, r.count == 8 { s += ">" + r }
            return ModuleTarget(spec: s)?.spec
        }
        return nil
    }
}

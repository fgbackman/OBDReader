import Foundation

struct AlertRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var pid: UInt8
    var below: Double?      // metric units
    var above: Double?      // metric units
    var enabled = true

    static let defaults: [AlertRule] = [
        AlertRule(pid: 0x05, below: nil, above: 110),        // coolant > 110 °C
        AlertRule(pid: 0x42, below: 12.0, above: 15.2),      // module voltage
        AlertRule(pid: 0x07, below: -15, above: 15),         // long-term fuel trim B1
        AlertRule(pid: 0x09, below: -15, above: 15),         // long-term fuel trim B2
        AlertRule(pid: 0x5C, below: nil, above: 135),        // oil temperature
    ]
}

struct CarProfile: Codable, Identifiable, Hashable {
    var vin: String
    var nickname: String
    var modelYear: Int?
    var isDiesel = false
    var dashboardPIDs: [UInt8] = PIDs.dashboardDefaults
    var menuBarPIDs: [UInt8] = [0x0C, 0x05]
    var alerts: [AlertRule] = AlertRule.defaults
    var lastSeen = Date()
    /// Engine layout, e.g. "W16". Optional so older garage files still load.
    var engineLayout: String?
    /// Manufacturer readings defined for this car (Custom Readings page). Optional for old files.
    var customPIDs: [CustomPID]?
    /// Extra module addresses to include in the All Modules scan.
    var extraModuleAddresses: [String]?
    /// Make / model for recall lookups (NHTSA searches by these, not by VIN).
    var make: String?
    var model: String?
    /// Where the car is kept: decides which inspection rules and record lookups apply.
    var region: String?
    /// UK number plate, for the MOT history lookup.
    var registration: String?
    /// Brand module list used by the All Modules scan (ModulePreset.brand).
    var modulePreset: String?
    /// Names given to measuring-block fields on this car, keyed "AA.GGG.F".
    var blockLabels: [String: String]?

    static let regions = ["California", "Florida", "Other US state", "England / UK"]
    static let regionUK = "England / UK"
    var id: String { vin }

    /// Cylinder count from the layout, if set.
    var cylinders: Int? { engineLayout.flatMap { EngineLayout.cylinders($0) } }
}

enum EngineLayout {
    static let all = ["I3", "I4", "I5", "I6", "V6", "V8", "V10", "V12", "W12", "W16", "Flat-4", "Flat-6"]
    static func cylinders(_ layout: String) -> Int? { Int(layout.filter(\.isNumber)) }

    /// First guess from the VIN maker code. Only makes that build one engine family get a guess.
    static func guess(vin: String) -> String? {
        switch String(vin.prefix(3)).uppercased() {
        case "VF9": return "W16"        // Bugatti Veyron / Chiron
        case "ZFF": return nil          // Ferrari: V8 or V12
        case "SCA": return "V12"        // Rolls-Royce
        default: return nil
        }
    }
}

struct SavedCode: Codable, Hashable {
    let code: String
    let kind: String
    let ecu: String
}

struct ScanRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var codes: [SavedCode]
    var milOn: Bool?
    var incompleteMonitors: [String]
    var snapshot: [UInt8: Double]
    var battery: Double?
    var failedTests: [String]
    var nearLimitTests: [String]
    var smogVerdict: String?
    // Added for the pre-purchase check. Optional so older history files still load.
    var software: [SoftwareID]?
    var vins: [String: String]?
    var odometerKm: Double?
    // Engine-health trend values (optional for older files)
    var misfireTotal: Int?
    var worstMargin: Double?
    var idleWobble: Double?
}

/// Stores car profiles and per-car scan history in ~/Library/Application Support/OBDReader.
@MainActor
final class GarageStore: ObservableObject {
    @Published private(set) var profiles: [CarProfile] = []

    static let unknownVIN = "UNKNOWN-VIN"

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("OBDReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("history"), withIntermediateDirectories: true)
        return d
    }()
    private var profilesURL: URL { dir.appendingPathComponent("garage.json") }
    private func historyURL(_ vin: String) -> URL {
        let safe = vin.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return dir.appendingPathComponent("history/\(safe).json")
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        if let data = try? Data(contentsOf: profilesURL),
           let list = try? decoder.decode([CarProfile].self, from: data) {
            profiles = list.sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    private func saveProfiles() {
        if let data = try? encoder.encode(profiles) { try? data.write(to: profilesURL, options: .atomic) }
    }

    /// Existing profile for this VIN, or a new one with sensible defaults.
    func profile(for vin: String) -> CarProfile {
        let key = vin.isEmpty ? Self.unknownVIN : vin
        if var p = profiles.first(where: { $0.vin == key }) {
            p.lastSeen = Date()
            update(p)
            return p
        }
        var p = CarProfile(vin: key,
                           nickname: key == Self.unknownVIN ? "Car without VIN" : "Car \(key.suffix(6))",
                           modelYear: VINDecoder.modelYear(key))
        p.engineLayout = EngineLayout.guess(vin: key)
        update(p)
        return p
    }

    func update(_ p: CarProfile) {
        if let i = profiles.firstIndex(where: { $0.vin == p.vin }) { profiles[i] = p } else { profiles.append(p) }
        profiles.sort { $0.lastSeen > $1.lastSeen }
        saveProfiles()
    }

    func delete(_ vin: String) {
        profiles.removeAll { $0.vin == vin }
        saveProfiles()
        try? FileManager.default.removeItem(at: historyURL(vin))
    }

    func history(_ vin: String) -> [ScanRecord] {
        guard let data = try? Data(contentsOf: historyURL(vin)),
              let list = try? decoder.decode([ScanRecord].self, from: data) else { return [] }
        return list.sorted { $0.date < $1.date }
    }

    func append(_ record: ScanRecord, vin: String) {
        var list = history(vin)
        list.append(record)
        if list.count > 500 { list.removeFirst(list.count - 500) }
        if let data = try? encoder.encode(list) { try? data.write(to: historyURL(vin), options: .atomic) }
        objectWillChange.send()
    }
}

enum VINDecoder {
    /// Model year from VIN position 10. The code repeats every 30 years, so pick the most
    /// recent year that isn't in the future. Editable in the Garage if it guesses wrong.
    static func modelYear(_ vin: String) -> Int? {
        let chars = Array(vin.uppercased())
        guard chars.count == 17 else { return nil }
        let codes = Array("ABCDEFGHJKLMNPRSTVWXY123456789")
        guard let idx = codes.firstIndex(of: chars[9]) else { return nil }
        let thisYear = Calendar.current.component(.year, from: Date())
        var year = 1980 + idx
        while year + 30 <= thisYear + 1 { year += 30 }
        return year
    }

    static func manufacturer(_ vin: String) -> String? {
        let wmi = String(vin.prefix(3)).uppercased()
        let known: [String: String] = [
            "VF9": "Bugatti", "WVW": "Volkswagen", "WAU": "Audi", "WP0": "Porsche", "WP1": "Porsche SUV",
            "ZFF": "Ferrari", "ZHW": "Lamborghini", "SCF": "Aston Martin", "SBM": "McLaren",
            "SCB": "Bentley", "SCA": "Rolls-Royce", "WBA": "BMW", "WDD": "Mercedes-Benz",
            "1FA": "Ford", "1G1": "Chevrolet", "1GC": "Chevrolet", "2G1": "Chevrolet", "3G1": "Chevrolet",
            "1GT": "GMC", "1G6": "Cadillac", "1G4": "Buick", "3VW": "Volkswagen", "5YJ": "Tesla", "JHM": "Honda", "JTD": "Toyota",
        ]
        return known[wmi]
    }
}

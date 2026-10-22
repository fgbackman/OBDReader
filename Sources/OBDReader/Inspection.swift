import Foundation

// MARK: - Software fingerprint (tune detection)

/// The calibration a control unit is running, from standard Mode 09:
/// CALID (InfoType 04, which software) and CVN (InfoType 06, a checksum of it).
/// If the CVN changes between scans, the software was rewritten — a dealer update or a tune.
struct SoftwareID: Codable, Hashable, Identifiable {
    var ecu: String
    var calids: [String]
    var cvns: [String]
    var id: String { ecu }
}

enum Mode09 {
    /// Data bytes of a Mode 09 reply with the service, InfoType and count/sequence bytes removed.
    /// CAN: one reassembled message [49, type, count, data…].
    /// Older protocols: one frame per sequence number [49, type, seq, d1…d4].
    static func payload(_ m: ECUMessage) -> [UInt8] {
        let frames = m.isCAN ? m.frames
            : m.frames.sorted { ($0.count > 2 ? $0[2] : 0) < ($1.count > 2 ? $1[2] : 0) }
        return frames.flatMap { $0.dropFirst(3) }
    }

    /// Printable text (VIN, ECU name).
    static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.filter { (0x20...0x7E).contains($0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Calibration IDs are 16 bytes each, padded with zeros.
    static func calids(_ bytes: [UInt8]) -> [String] {
        stride(from: 0, to: bytes.count, by: 16).compactMap { i in
            let s = text(Array(bytes[i..<min(i + 16, bytes.count)]))
            return s.isEmpty ? nil : s
        }
    }

    /// Calibration verification numbers are 4 bytes each, shown as hex.
    static func cvns(_ bytes: [UInt8]) -> [String] {
        stride(from: 0, to: bytes.count - 3, by: 4).map { i in
            bytes[i..<i + 4].map { String(format: "%02X", $0) }.joined()
        }
    }
}

// MARK: - Pre-purchase inspection

struct InspectionFlag: Identifiable {
    enum Level: Int, Comparable {
        case ok = 0, info = 1, caution = 2, red = 3
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var label: String { ["Looks fine", "Note", "Ask about it", "Red flag"][rawValue] }
    }
    let id = UUID()
    let level: Level
    let title: String
    let detail: String
}

/// What the OBD data says about a used car before you buy it: signs the codes were wiped just
/// before the viewing, monitors that haven't finished, codes the seller can't erase, odometer
/// disagreements, swapped modules and changed engine software.
struct PrePurchaseReport {
    let flags: [InspectionFlag]

    var redCount: Int { flags.filter { $0.level == .red }.count }
    var cautionCount: Int { flags.filter { $0.level == .caution }.count }
    var worst: InspectionFlag.Level { flags.map(\.level).max() ?? .ok }

    var verdict: String {
        switch worst {
        case .red: return "Red flags — get answers (or a dealer inspection) before buying"
        case .caution: return "A few things to ask the seller about"
        default: return "Nothing suspicious in the OBD data"
        }
    }

    struct Inputs {
        var readiness: Readiness?
        var dtcs: [DTC]
        var live: [UInt8: Double]
        var vins: [String: String]          // ECU → VIN
        var software: [SoftwareID]
        var previous: ScanRecord?
        var dashOdometerKm: Double?
        var tests: [TestResult]
        var battery: Double?
        var units: UnitSystem
        var moduleOdometers: [String: Double] = [:]   // e.g. "Instruments (17) group 002" → km
    }

    static func build(_ x: Inputs) -> PrePurchaseReport {
        var f: [InspectionFlag] = []
        func dist(_ km: Double) -> String { UnitKind.distance.format(km, x.units) }

        // 1. Were the codes cleared just before the viewing?
        let warm = x.live[0x30], km = x.live[0x31], mins = x.live[0x4E]
        if warm != nil || km != nil {
            var parts: [String] = []
            if let w = warm { parts.append("\(Int(w)) warm-up\(Int(w) == 1 ? "" : "s")") }
            if let k = km { parts.append(dist(k)) }
            if let m = mins { parts.append(m >= 120 ? "\(Int(m / 60)) h of running" : "\(Int(m)) min of running") }
            let since = parts.joined(separator: ", ")
            let w = warm ?? 255, k = km ?? 65535
            if w < 5 || k < 80 {
                f.append(InspectionFlag(level: .red, title: "Codes were cleared very recently",
                    detail: "Only \(since) since the codes were last cleared or the battery was disconnected. Sellers sometimes do this to hide a check-engine light before a viewing. Ask why, and ideally re-scan after the seller's car has done a few days of normal driving."))
            } else if w < 20 || k < 320 {
                f.append(InspectionFlag(level: .caution, title: "Codes were cleared fairly recently",
                    detail: "\(since) since the last clear or battery disconnect. Could be innocent (battery replaced, recent service), but worth asking about."))
            } else {
                f.append(InspectionFlag(level: .ok, title: "No sign of a recent code clear",
                    detail: "\(since) since codes were last cleared."))
            }
        } else {
            f.append(InspectionFlag(level: .info, title: "Can't tell when codes were last cleared",
                detail: "This car doesn't report warm-ups or distance since clearing, so a recent wipe can't be ruled out. Readiness below is the next-best clue."))
        }

        // 2. Readiness monitors
        if let r = x.readiness {
            let inc = r.monitors.filter { !$0.complete }.map(\.name)
            if inc.count >= 2 {
                f.append(InspectionFlag(level: .caution, title: "\(inc.count) readiness monitors not finished",
                    detail: "\(inc.joined(separator: ", ")). Normal right after a clear or battery change; a car that's been driven normally for a week usually has these done. Combined with a recent clear, it suggests something was hidden."))
            } else if inc.count == 1 {
                f.append(InspectionFlag(level: .info, title: "1 readiness monitor not finished",
                    detail: "\(inc[0]). Common on some cars (EVAP especially) and not a concern on its own."))
            } else {
                f.append(InspectionFlag(level: .ok, title: "All readiness monitors complete",
                    detail: "The car has finished all its emissions self-checks since the last clear."))
            }
        }

        // 3. Codes
        let permanent = x.dtcs.filter { $0.kind == .permanent }
        if !permanent.isEmpty {
            f.append(InspectionFlag(level: .red, title: "Permanent code\(permanent.count == 1 ? "" : "s"): \(permanent.map(\.code).joined(separator: ", "))",
                detail: "A scanner can't erase permanent codes — they only go away once the car itself confirms the fault is fixed. If the check-engine light is off but a permanent code is here, the codes were cleared without a repair."))
        }
        let stored = x.dtcs.filter { $0.kind == .stored }
        if x.readiness?.milOn == true {
            f.append(InspectionFlag(level: .red, title: "Check-engine light is on",
                detail: stored.isEmpty ? "The light is on but no generic code was read — a manufacturer tool is needed to see why."
                                       : "Codes: \(stored.map(\.code).joined(separator: ", ")). See Trouble Codes and Diagnosis."))
        } else if !stored.isEmpty {
            f.append(InspectionFlag(level: .caution, title: "Stored code\(stored.count == 1 ? "" : "s") without the warning light",
                detail: "\(stored.map(\.code).joined(separator: ", ")). Not all codes light the lamp, but each one is a question for the seller."))
        }
        let pending = x.dtcs.filter { $0.kind == .pending }
        if !pending.isEmpty {
            f.append(InspectionFlag(level: .caution, title: "Pending code\(pending.count == 1 ? "" : "s"): \(pending.map(\.code).joined(separator: ", "))",
                detail: "The car has seen this fault once and is waiting to confirm it. It often turns into a check-engine light within a few drives."))
        }
        if stored.isEmpty && pending.isEmpty && permanent.isEmpty && x.readiness?.milOn != true {
            f.append(InspectionFlag(level: .ok, title: "No trouble codes", detail: "No stored, pending or permanent generic codes."))
        }
        if let milKm = x.live[0x21], milKm > 0 {
            var d = "The car has been driven \(dist(milKm)) with the check-engine light on"
            if let m = x.live[0x4D], m > 0 { d += " (\(Int(m)) min of running)" }
            f.append(InspectionFlag(level: .caution, title: "Driven with the warning light on", detail: d + "."))
        }

        // 4. Odometer
        let ecuOdo = x.live[0xA6]
        if let o = ecuOdo {
            f.append(InspectionFlag(level: .info, title: "Engine computer odometer: \(dist(o))",
                detail: "Stored by the car's own computer (2019+ cars mostly). Compare it with the dashboard reading below."))
        }
        if let o = ecuOdo, let dash = x.dashOdometerKm, dash > 0 {
            let diff = abs(o - dash)
            if diff > max(500, dash * 0.05) {
                f.append(InspectionFlag(level: .red, title: "Odometer readings disagree",
                    detail: "Dashboard \(dist(dash)) vs engine computer \(dist(o)) — a \(dist(diff)) difference. Could be a replaced cluster or a rolled-back odometer. Ask for the service history."))
            } else {
                f.append(InspectionFlag(level: .ok, title: "Odometer readings agree",
                    detail: "Dashboard and engine computer are within \(dist(diff))."))
            }
        }
        if let o = ecuOdo, let prev = x.previous?.odometerKm, o + 1 < prev {
            f.append(InspectionFlag(level: .red, title: "Odometer went backwards",
                detail: "\(dist(prev)) at the scan on \(x.previous!.date.formatted(date: .abbreviated, time: .omitted)), \(dist(o)) now."))
        }

        // 4b. Mileage stored in other modules (measuring blocks / custom readings)
        if let o = ecuOdo ?? x.dashOdometerKm {
            // Ignore small km values (service-interval countdowns use the same unit).
            for (src, km) in x.moduleOdometers.sorted(by: { $0.key < $1.key }) where km > o * 0.5 {
                let diff = abs(o - km)
                if diff > max(500, o * 0.05) {
                    f.append(InspectionFlag(level: .red, title: "Stored mileage disagrees: \(src)",
                        detail: "\(src) holds \(dist(km)) but the car shows \(dist(o)). A replaced module, or an odometer that was changed in one place only."))
                } else {
                    f.append(InspectionFlag(level: .ok, title: "Stored mileage agrees: \(src)", detail: "\(dist(km)) vs \(dist(o))."))
                }
            }
        }

        // 5. VIN across modules
        let distinct = Set(x.vins.values.filter { $0.count == 17 })
        if distinct.count > 1 {
            let list = x.vins.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            f.append(InspectionFlag(level: .red, title: "Modules report different VINs",
                detail: "\(list). A module from another car has been fitted — possibly after an accident or theft recovery. Check the VIN plate and title too."))
        } else if x.vins.count > 1 {
            f.append(InspectionFlag(level: .ok, title: "VIN matches across \(x.vins.count) modules", detail: distinct.first ?? ""))
        }

        // 6. Engine software
        if !x.software.isEmpty {
            let withCVN = x.software.filter { !$0.cvns.isEmpty }
            if let prev = x.previous?.software, !prev.isEmpty {
                var changed: [String] = []
                for now in x.software {
                    guard let before = prev.first(where: { $0.ecu == now.ecu }) else { continue }
                    if before.cvns != now.cvns || before.calids != now.calids { changed.append(now.ecu) }
                }
                if !changed.isEmpty {
                    f.append(InspectionFlag(level: .caution, title: "Engine software changed since the last scan",
                        detail: "Control unit \(changed.joined(separator: ", ")) is running different software than on \(x.previous!.date.formatted(date: .abbreviated, time: .omitted)). Either a dealer update or an aftermarket tune — ask which, and for the paperwork."))
                } else {
                    f.append(InspectionFlag(level: .ok, title: "Engine software unchanged since the last scan",
                        detail: "Same calibration and checksum as on \(x.previous!.date.formatted(date: .abbreviated, time: .omitted))."))
                }
            } else {
                f.append(InspectionFlag(level: .info, title: "Software fingerprint recorded",
                    detail: "\(x.software.count) control unit\(x.software.count == 1 ? "" : "s") reported a calibration ID\(withCVN.isEmpty ? "" : " and checksum"). Saved with this scan — a later scan will show if it changes. To check for a tune now, compare the calibration IDs with a known-stock car of the same model and year, or ask a dealer."))
            }
            if withCVN.isEmpty {
                f.append(InspectionFlag(level: .info, title: "No software checksum reported",
                    detail: "The car gave calibration IDs but no verification number (CVN), so a re-flash that keeps the same ID can't be detected."))
            }
        }

        // 7. Self-tests and battery
        let failed = x.tests.filter { !$0.passed }
        if !failed.isEmpty {
            f.append(InspectionFlag(level: .caution, title: "\(failed.count) self-test\(failed.count == 1 ? "" : "s") failing",
                detail: "\(failed.prefix(4).map { "\($0.monitorName): \($0.testName)" }.joined(separator: "; ")). The car measured these out of range even if no light is on yet."))
        }
        if let v = x.battery, (x.live[0x0C] ?? 0) < 300, v < 12.2 {
            f.append(InspectionFlag(level: .info, title: String(format: "Battery low (%.1f V)", v),
                detail: "May just have been sitting, but a weak battery can also cause odd codes. Run the Battery Test."))
        }

        return PrePurchaseReport(flags: f.sorted { $0.level > $1.level })
    }
}

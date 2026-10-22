import Foundation
import SwiftUI

// MARK: - VCDS Auto-Scan reports
//
// VCDS saves an Auto-Scan as plain text: a header (VCDS version, VIN, mileage), a summary line per
// module ("01-Engine -- Status: Malfunction 0010"), then one block per module:
//
//   Address 08: Auto HVAC (J255)       Labels: 4G0-820-043-4Z.clb
//      Part No SW: ...    HW: ...
//      Component: ...
//      Coding: ...
//   2 Faults Found:                     (or "No fault code found.")
//   0276 - Engine Off Timer Performance
//             P150A 00 [008] - -
//             Intermittent - Confirmed - Tested Since Memory Clear
//                Freeze Frame:
//                       Fault Priority: 2
//                       Mileage: 12345 km
//
// Older modules print the second line as "P0303 - 008 - Implausible Signal" or "35-10 - - - Intermittent".
// The reader is tolerant: unknown lines are skipped, not fatal.

struct VagFault: Identifiable {
    let id = UUID()
    var vagCode: String            // VW's own number, e.g. "0276" or "16687"
    var description: String
    var dtc: String = ""           // P/C/B/U code when shown
    var detail: String = ""        // e.g. "00 [008] - -" or "008 - Implausible Signal"
    var status: [String] = []      // e.g. "Intermittent - Confirmed - Tested Since Memory Clear"
    var freezeFrame: [(String, String)] = []

    var isIntermittent: Bool { status.joined(separator: " ").localizedCaseInsensitiveContains("intermittent") }
}

struct VagModule: Identifiable {
    let id = UUID()
    var address: String
    var name: String
    var summaryStatus: String = ""      // from the summary list, e.g. "Malfunction 0010"
    var partNumbers: String = ""
    var component: String = ""
    var coding: String = ""
    var faults: [VagFault] = []
    var noFaults = false
}

struct AutoScanReport: Identifiable {
    let id = UUID()
    let fileName: String
    var toolVersion = ""
    var vin = ""
    var mileage = ""
    var chassis = ""
    var dateLine = ""
    var modules: [VagModule] = []

    var faultCount: Int { modules.reduce(0) { $0 + $1.faults.count } }
}

enum AutoScanParser {
    /// Quick check so the import button can route text files to the right reader.
    static func looks(like text: String) -> Bool {
        text.contains("Address ") && (text.contains("Fault") || text.contains("fault")) && text.contains("Ross-Tech")
            || text.contains("Chassis Type:") && text.contains("Address ")
    }

    static func parse(_ raw: String, fileName: String) -> AutoScanReport? {
        let text = raw.replacingOccurrences(of: "∞C", with: "°C")      // some saves mis-encode the degree sign
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var r = AutoScanReport(fileName: fileName)
        var summary: [String: (name: String, status: String)] = [:]
        var current: VagModule?
        var fault: VagFault?
        var inFreeze = false

        func flushFault() {
            if let f = fault { current?.faults.append(f) }
            fault = nil
            inFreeze = false
        }
        func flushModule() {
            flushFault()
            if var m = current {
                if let s = summary[m.address] { m.summaryStatus = s.status }
                r.modules.append(m)
            }
            current = nil
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let indented = rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t")
            if line.isEmpty { continue }

            // Header
            if line.hasPrefix("VCDS Version:") || line.hasPrefix("VCDS -- ") { if r.toolVersion.isEmpty { r.toolVersion = line } ; continue }
            if line.hasPrefix("VIN:") {
                r.vin = field(line, "VIN:", until: "License Plate:")
                continue
            }
            if line.hasPrefix("Mileage:") && current == nil { r.mileage = field(line, "Mileage:", until: "Repair Order:"); continue }
            if line.hasPrefix("Chassis Type:") { r.chassis = String(line.dropFirst("Chassis Type:".count)).trimmingCharacters(in: .whitespaces); continue }
            if r.dateLine.isEmpty, current == nil, r.toolVersion.isEmpty, line.contains(",") { r.dateLine = line; continue }
            if line.hasPrefix("---") || line.hasPrefix("End-") || line.hasPrefix("End ") { continue }

            // Summary: "01-Engine -- Status: Malfunction 0010"
            if current == nil, let dash = line.firstIndex(of: "-"), line.distance(from: line.startIndex, to: dash) == 2,
               let statusRange = line.range(of: "-- Status:") {
                let addr = String(line.prefix(2)).uppercased()
                let name = line[line.index(after: dash)..<statusRange.lowerBound].trimmingCharacters(in: .whitespaces)
                let status = line[statusRange.upperBound...].trimmingCharacters(in: .whitespaces)
                summary[addr] = (name, status)
                continue
            }

            // Module header: "Address 08: Auto HVAC (J255)    Labels: …"
            if line.hasPrefix("Address ") {
                flushModule()
                let rest = line.dropFirst("Address ".count)
                guard let colon = rest.firstIndex(of: ":") else { continue }
                let addr = rest[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
                var name = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let l = name.range(of: "Labels:") { name = name[..<l.lowerBound].trimmingCharacters(in: .whitespaces) }
                current = VagModule(address: addr, name: name)
                continue
            }

            guard current != nil else { continue }

            // Identification lines
            if fault == nil {
                if line.hasPrefix("Part No") {
                    let old = current?.partNumbers ?? ""
                    current?.partNumbers = old.isEmpty ? line : old + "; " + line
                    continue
                }
                if line.hasPrefix("Component:") {
                    if (current?.component ?? "").isEmpty { current?.component = field(line, "Component:", until: nil) }
                    continue
                }
                if line.hasPrefix("Coding:") {
                    if (current?.coding ?? "").isEmpty { current?.coding = field(line, "Coding:", until: nil) }
                    continue
                }
            }
            if line.hasPrefix("No fault code found") { current?.noFaults = true; continue }
            if line.hasSuffix("Found:") && (line.contains("Fault") || line.contains("fault")) { continue }

            // New fault: unindented "NNNN - Description" (or a bare DTC at column 0 in old reports)
            if !indented, let cd = codeAndText(line) {
                flushFault()
                fault = VagFault(vagCode: cd.0, description: cd.1)
                if isDTC(cd.0) { fault?.dtc = cd.0 }
                continue
            }

            guard fault != nil else { continue }

            // Inside a fault
            if line.hasPrefix("Freeze Frame") { inFreeze = true; continue }
            if inFreeze, let c = line.firstIndex(of: ":") {
                let k = line[..<c].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                fault?.freezeFrame.append((k, v))
                continue
            }
            let first = line.split(separator: " ").first.map(String.init) ?? ""
            if fault!.dtc.isEmpty, isDTC(first) {
                fault?.dtc = first
                fault?.detail = line.dropFirst(first.count).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
                if line.localizedCaseInsensitiveContains("intermittent") { fault?.status.append("Intermittent") }
                continue
            }
            if fault!.detail.isEmpty, line.first?.isNumber == true, line.contains(" - ") {
                fault?.detail = line                       // old "35-10 - - - Intermittent"
                if line.localizedCaseInsensitiveContains("intermittent") { fault?.status.append("Intermittent") }
                continue
            }
            fault?.status.append(line)
        }
        flushModule()
        // Modules only in the summary (e.g. "Cannot be reached") still matter.
        for (addr, s) in summary where !r.modules.contains(where: { $0.address == addr }) {
            r.modules.append(VagModule(address: addr, name: s.name, summaryStatus: s.status))
        }
        r.modules.sort { $0.address < $1.address }
        return r.modules.isEmpty ? nil : r
    }

    private static func field(_ line: String, _ key: String, until end: String?) -> String {
        var s = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        if let end, let r = s.range(of: end) { s = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// "0276 - Engine Off Timer Performance" → ("0276", "Engine Off Timer Performance")
    private static func codeAndText(_ line: String) -> (String, String)? {
        guard let r = line.range(of: " - ") else { return nil }
        let code = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        let isVag = (4...6).contains(code.count) && code.allSatisfy(\.isNumber)
        guard isVag || isDTC(code) else { return nil }
        return (code, line[r.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    static func isDTC(_ s: String) -> Bool {
        guard s.count == 5, let f = s.first, "PCBU".contains(f) else { return false }
        return s.dropFirst().allSatisfy(\.isHexDigit)
    }
}

// MARK: - View

struct AutoScanCard: View {
    let report: AutoScanReport
    let onRemove: () -> Void
    @State private var showClean = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                    Text(report.fileName).font(.headline)
                    Text("VCDS Auto-Scan").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(report.faultCount) fault\(report.faultCount == 1 ? "" : "s") in \(report.modules.filter { !$0.faults.isEmpty }.count) module\(report.modules.filter { !$0.faults.isEmpty }.count == 1 ? "" : "s")")
                        .font(.caption.bold()).foregroundStyle(report.faultCount == 0 ? Color.green : Color.orange)
                    Button(role: .destructive, action: onRemove) { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                }
                Group {
                    if !report.vin.isEmpty { Text("VIN \(report.vin)") }
                    if !report.mileage.isEmpty { Text("Mileage \(report.mileage)") }
                    if !report.chassis.isEmpty { Text("Chassis \(report.chassis)") }
                    if !report.toolVersion.isEmpty { Text(report.toolVersion) }
                }
                .font(.caption).foregroundStyle(.secondary)

                ForEach(report.modules.filter { !$0.faults.isEmpty }) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(m.address) · \(m.name)").font(.subheadline.bold())
                        ForEach(m.faults) { f in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(f.dtc.isEmpty ? f.vagCode : f.dtc).font(.system(.body, design: .monospaced).bold())
                                        .foregroundStyle(f.isIntermittent ? Color.orange : Color.red)
                                        .frame(width: 80, alignment: .leading)
                                    Text(f.description)
                                }
                                let extra = ([f.detail] + f.status).filter { !$0.isEmpty && $0 != "-" }
                                if !extra.isEmpty {
                                    Text(extra.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).padding(.leading, 88)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                let unreachable = report.modules.filter { $0.summaryStatus.localizedCaseInsensitiveContains("cannot be reached") }
                if !unreachable.isEmpty {
                    Text("Couldn't be reached: " + unreachable.map { "\($0.address) \($0.name)" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("Modules with no faults (\(report.modules.filter { $0.faults.isEmpty }.count))", isExpanded: $showClean) {
                    ForEach(report.modules.filter { $0.faults.isEmpty }) { m in
                        Text("\(m.address) · \(m.name)\(m.summaryStatus.isEmpty ? "" : " — \(m.summaryStatus)")")
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption)
            }
        }
    }
}

extension AutoScanReport {
    func markdown() -> String {
        var r = "- **\(fileName)** (VCDS Auto-Scan\(vin.isEmpty ? "" : ", VIN \(vin)")\(mileage.isEmpty ? "" : ", \(mileage)")): \(faultCount) fault\(faultCount == 1 ? "" : "s")\n"
        for m in modules where !m.faults.isEmpty {
            r += "    - \(m.address) \(m.name)\n"
            for f in m.faults {
                r += "        - \(f.dtc.isEmpty ? f.vagCode : "\(f.dtc) (\(f.vagCode))") — \(f.description)"
                if !f.status.isEmpty { r += " — \(f.status.joined(separator: "; "))" }
                r += "\n"
            }
        }
        return r
    }
}

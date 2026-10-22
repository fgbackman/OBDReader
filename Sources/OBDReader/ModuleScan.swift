import Foundation
import SwiftUI

// MARK: - Fault codes from every module (UDS, read-only)
//
// Generic OBD-II (Modes 03/07/0A) only returns emissions codes. On most CAN cars each module
// also answers the ISO 14229 (UDS) request 19 02 FF — "report DTCs matching any status" — which
// includes its non-emissions codes. Nothing is written or cleared. Older modules that only speak
// KWP2000, or VW's older TP2.0 transport, won't answer this.

struct ModuleDTC: Identifiable, Hashable {
    let code: String          // P/C/B/U code from the first two bytes (SAE J2012 format)
    let ftb: UInt8            // failure type byte (manufacturer-specific detail)
    let status: UInt8

    var id: String { code + String(format: "-%02X", Int(ftb)) }
    var display: String { ftb == 0 ? code : code + String(format: "-%02X", Int(ftb)) }

    // ISO 14229 DTC status bits
    var testFailed: Bool { status & 0x01 != 0 }
    var pending: Bool { status & 0x04 != 0 }
    var confirmed: Bool { status & 0x08 != 0 }
    var warningLamp: Bool { status & 0x80 != 0 }
    var failedSinceClear: Bool { status & 0x20 != 0 }

    var statusText: String {
        var parts: [String] = []
        if testFailed { parts.append("failing now") }
        if confirmed { parts.append("confirmed") }
        if pending { parts.append("pending") }
        if warningLamp { parts.append("warning light requested") }
        if parts.isEmpty && failedSinceClear { parts.append("failed since last clear (not now)") }
        if parts.isEmpty { parts.append("stored (inactive)") }
        return parts.joined(separator: ", ")
    }

    var description: String {
        let generic = DTCDatabase.describe(code)
        return generic
    }
}

struct ModuleReport: Identifiable {
    let address: String       // request address, e.g. "7E1"
    var responder = ""        // reply address, e.g. "7E9"
    var name: String?         // module name from the brand list
    var dtcs: [ModuleDTC] = []
    var identification: [(label: String, value: String)] = []
    var note: String?
    var answered = false
    var id: String { address }
}

enum UDS {
    /// Parse a 59 02 reply: [59, 02, availabilityMask, (DTC hi, mid, low, status)…]
    static func parseDTCs(_ f: [UInt8]) -> [ModuleDTC]? {
        guard f.count >= 3, f[0] == 0x59, f[1] == 0x02 else { return nil }
        var out: [ModuleDTC] = []
        var i = 3
        while i + 3 < f.count {
            if let code = DTC.decode(f[i], f[i + 1]) {
                out.append(ModuleDTC(code: code, ftb: f[i + 2], status: f[i + 3]))
            }
            i += 4
        }
        return out
    }

    /// Standard ISO 14229 identification data identifiers.
    static let identifiers: [(did: String, label: String)] = [
        ("F190", "VIN"), ("F187", "Part number"), ("F189", "Software version"),
        ("F191", "Hardware number"), ("F18C", "Serial number"), ("F197", "System name"),
        ("F18A", "Supplier"), ("F18B", "Manufacturing date"), ("F192", "Supplier hardware number"),
        ("F193", "Supplier hardware version"), ("F194", "Supplier software number"), ("F195", "Supplier software version"),
    ]

    /// Common negative response codes (ISO 14229).
    static func nrcText(_ c: UInt8) -> String {
        switch c {
        case 0x10: return "general reject"
        case 0x11: return "service not supported"
        case 0x12: return "sub-function not supported"
        case 0x13: return "wrong message length"
        case 0x22: return "conditions not correct"
        case 0x31: return "identifier not supported"
        case 0x33: return "security access required"
        case 0x78: return "busy, response pending"
        case 0x7E, 0x7F: return "not supported in this session"
        default: return "refused"
        }
    }

    /// 11-bit reply address → request address (7E8 → 7E0). 29-bit "18DAF1xx" → "18DAxxF1".
    static func requestAddress(forResponder ecu: String, is29Bit: Bool) -> String? {
        if is29Bit { return ecu.count == 2 ? "18DA\(ecu)F1" : nil }
        guard let v = Int(ecu, radix: 16), (0x7E8...0x7EF).contains(v) else { return nil }
        return String(format: "%03X", v - 8)
    }
}

// MARK: - Page

struct AllModulesView: View {
    @EnvironmentObject var s: VehicleSession
    @State private var readIDs = true
    @State private var newAddress = ""
    @State private var autoConfirm = false

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        PageHeader(title: "All Modules",
                                   subtitle: "Fault codes from every module that answers, not just emissions — read-only")
                        Spacer()
                        Toggle("Part & software numbers", isOn: $readIDs).toggleStyle(.checkbox)
                        Button("Scan modules") { Task { await s.scanModules(readIDs: readIDs) } }
                            .disabled(s.busy != nil || !s.isCAN)
                        Button("Auto-Scan") { autoConfirm = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(s.busy != nil || !s.isCAN)
                            .help("Find every module, read its codes and part numbers, and save the result")
                    }
                    if !s.isCAN {
                        Label("Module scanning needs a CAN car (most 2008+). This car uses \(s.protocolName).", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Addresses scanned").font(.headline)
                                Spacer()
                                Picker("Brand list", selection: Binding(
                                    get: { s.modulePreset?.brand ?? "none" },
                                    set: { s.setModulePreset($0) })) {
                                    Text("None").tag("none")
                                    ForEach(ModulePreset.all) { Text($0.brand).tag($0.brand) }
                                }
                                .frame(width: 340)
                            }
                            Text(s.moduleAddresses.map { spec in
                                s.moduleName(spec).map { "\(spec) \($0)" } ?? spec
                            }.joined(separator: "  ·  "))
                            .font(.callout.monospaced()).textSelection(.enabled)
                            if let p = s.modulePreset {
                                Text(p.note).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Starts with the modules that answered the standard requests plus the usual 7E0–7E7 range. Pick a brand list to add that maker's other modules.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !s.skippedModuleAddresses.isEmpty {
                                Text("Skipped (this car uses \(s.protocolName.contains("29-bit") ? "29-bit" : "11-bit") CAN IDs): \(s.skippedModuleAddresses.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                TextField("Add address, e.g. 713>77D", text: $newAddress)
                                    .textFieldStyle(.roundedBorder).frame(width: 220)
                                Button("Add") { s.addModuleAddress(newAddress); newAddress = "" }
                                    .disabled(ModuleTarget(spec: newAddress) == nil)
                                if !(s.profile?.extraModuleAddresses ?? []).isEmpty {
                                    Button("Reset extras") { s.clearExtraModuleAddresses() }
                                }
                            }
                            Text("Format: request address, optionally /extended byte and >reply address — 7E1, 713>77D, 6F1/12>612, 18DA28F1.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    SweepCard()
                    TP20Card()
                    LibraryCard()
                    if s.lastModuleScan != nil || s.lastTP20Scan != nil {
                        HStack {
                            Spacer()
                            Button("Save Auto-Scan report…") { s.exportAutoScanReport() }
                        }
                    }
                    if let t = s.lastModuleScan {
                        Text("Scanned \(t.formatted(date: .omitted, time: .shortened)) · \(s.moduleReports.filter(\.answered).count) module\(s.moduleReports.filter(\.answered).count == 1 ? "" : "s") answered")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(s.moduleReports.filter(\.answered)) { ModuleCard(report: $0, carVIN: s.vin, make: s.profile?.make ?? VINDecoder.manufacturer(s.vin)) }
                    let silent = s.moduleReports.filter { !$0.answered }.map(\.address)
                    if !silent.isEmpty {
                        Text("No reply from: \(silent.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .confirmationDialog("Run Auto-Scan?", isPresented: $autoConfirm) {
                Button("Start (car parked, engine off)") { Task { await s.autoScan() } }
            } message: {
                Text("Sweeps every diagnostic address, then reads fault codes and part numbers from each module that answers, and saves the module list to our library. Read-only — takes a few minutes.")
            }
        }
    }
}

struct ModuleCard: View {
    let report: ModuleReport
    var carVIN: String = ""
    var make: String? = nil
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "cpu").foregroundStyle(.secondary)
                    Text(report.name ?? "Module \(report.address)").font(.headline)
                    if report.name != nil { Text(report.address).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if !report.responder.isEmpty {
                        Text("replies as \(report.responder)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(report.dtcs.isEmpty ? "No codes" : "\(report.dtcs.count) code\(report.dtcs.count == 1 ? "" : "s")")
                        .font(.caption.bold())
                        .foregroundStyle(report.dtcs.isEmpty ? Color.green : Color.orange)
                }
                if !report.identification.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                        ForEach(report.identification, id: \.label) { row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary)
                                Text(row.value).monospaced().textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)
                }
                if let n = report.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                if let mv = report.identification.first(where: { $0.label == "VIN" })?.value, mv.count == 17,
                   !carVIN.isEmpty, mv != carVIN {
                    Label("This module reports a different VIN (\(mv)) — it may come from another car.", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                ForEach(report.dtcs) { d in
                    HStack(alignment: .top, spacing: 12) {
                        Text(d.display).font(.system(.body, design: .monospaced).bold())
                            .foregroundStyle(d.testFailed || d.confirmed ? Color.red : Color.orange)
                            .frame(width: 110, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.description)
                            if let ft = FailureType.describe(d.ftb, make: make) {
                                Text("How it failed: \(ft)").font(.caption).foregroundStyle(Color.primary.opacity(0.8))
                            }
                            Text(d.statusText).font(.caption).foregroundStyle(.secondary)
                            if let c = DTCDatabase.causes(d.code) {
                                Text("Common causes: \(c)").font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

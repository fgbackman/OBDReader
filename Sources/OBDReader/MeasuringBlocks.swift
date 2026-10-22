import SwiftUI
import AppKit
import UniformTypeIdentifiers

// VW-group measuring blocks (what VCDS calls "Measuring Blocks"): live values read from one module
// as numbered groups of up to 4 fields. KWP2000 over TP2.0: request 21 <group>, reply
// 61 <group> followed by fields of [type, A, B]; the type byte says how to turn A and B into a value.
//
// Formula sources (open source, read October 2026):
//   types 01–46: gmenounos/kw1281test Blocks/SensorValue.cs (itself based on blafusel.de)
//   types 47–B5: domnulvlad/KLineKWP1281Lib src/KLineKWP1281Lib.cpp
//   layout and session handling: jazdw/vag-blocks kwp2000.cpp
// Read-only: service 21 only.

struct BlockField: Identifiable, Hashable {
    let index: Int
    let type: UInt8
    let raw: [UInt8]
    let value: Double?
    let text: String          // what to show (number already formatted, or text)
    let unit: String
    var id: Int { index }
    var rawText: String { String(format: "%02X ", type) + raw.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

struct GroupReading: Identifiable {
    let group: UInt8
    var fields: [BlockField] = []
    var error: String?
    var id: UInt8 { group }
    var groupText: String { String(format: "%03d", Int(group)) }
}

enum VAGBlocks {
    /// Split a 61 <group> reply into fields. Most fields are 3 bytes; a few types are length-prefixed
    /// text or run to the end of the reply. Trailing 25 00 00 cells are padding.
    static func reading(group: UInt8, reply: [UInt8]?) -> GroupReading {
        guard let r = reply else { return GroupReading(group: group, error: "No answer") }
        if r.first == 0x7F {
            let nrc = r.count >= 3 ? UDS.nrcText(r[2]) : "refused"
            return GroupReading(group: group, error: "Group not available (\(nrc))")
        }
        guard r.count >= 2, r[0] == 0x61 else { return GroupReading(group: group, error: "Unexpected reply") }
        let p = Array(r.dropFirst(2))
        var fields: [BlockField] = []
        var i = 0
        while i < p.count {
            let t = p[i]
            switch t {
            case 0x3F:                                              // text to the end
                let data = Array(p[(i + 1)...])
                fields.append(BlockField(index: fields.count, type: t, raw: data, value: nil, text: ascii(data), unit: ""))
                i = p.count
            case 0x5F, 0x76:                                        // length-prefixed text / hex
                guard i + 1 < p.count else { i = p.count; break }
                let len = Int(p[i + 1])
                let end = min(p.count, i + 2 + len)
                let data = Array(p[(i + 2)..<end])
                let text = t == 0x5F ? ascii(data) : data.map { String(format: "%02X", $0) }.joined(separator: " ")
                fields.append(BlockField(index: fields.count, type: t, raw: data, value: nil, text: text, unit: ""))
                i = end
            case 0xA0:                                              // variable units (6 bytes): show raw
                let end = min(p.count, i + 6)
                let data = Array(p[(i + 1)..<end])
                fields.append(BlockField(index: fields.count, type: t, raw: data, value: nil,
                                         text: data.map { String(format: "%02X", $0) }.joined(separator: " "), unit: ""))
                i = end
            default:
                guard i + 2 < p.count else { i = p.count; break }
                let a = p[i + 1], b = p[i + 2]
                fields.append(decode(index: fields.count, type: t, a: a, b: b))
                i += 3
            }
        }
        while let last = fields.last, last.type == 0x25, last.raw == [0, 0] { fields.removeLast() }
        return GroupReading(group: group, fields: fields)
    }

    static func ascii(_ d: [UInt8]) -> String {
        String(decoding: d.filter { (0x20...0x7E).contains($0) }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    static func decode(index: Int, type t: UInt8, a ai: UInt8, b bi: UInt8) -> BlockField {
        let A = Double(ai), B = Double(bi)
        let s16 = Double(Int16(bitPattern: UInt16(ai) << 8 | UInt16(bi)))
        let u16 = Double(Int(ai) << 8 | Int(bi))
        let sB = Double(Int8(bitPattern: bi))
        func num(_ v: Double, _ unit: String) -> BlockField {
            BlockField(index: index, type: t, raw: [ai, bi], value: v, text: format(v), unit: unit)
        }
        func txt(_ s: String, _ unit: String = "") -> BlockField {
            BlockField(index: index, type: t, raw: [ai, bi], value: nil, text: s, unit: unit)
        }
        switch t {
        case 0x01: return num(0.2 * A * B, "rpm")
        case 0x02: return num(0.002 * A * B, "%")
        case 0x03: return num(0.002 * A * B, "°")
        case 0x04: return num(abs(B - 127) * 0.01 * A, B > 127 ? "° ATDC" : "° BTDC")
        case 0x05: return num(A * (B - 100) * 0.1, "°C")
        case 0x06: return num(0.001 * A * B, "V")
        case 0x07: return num(0.01 * A * B, "km/h")
        case 0x08: return num(0.1 * A * B, "")
        case 0x09: return num((B - 127) * 0.02 * A, "°")
        case 0x0A: return txt(bi == 0 ? "Cold" : "Warm")
        case 0x0B: return num(0.0001 * A * (B - 128) + 1, "λ")
        case 0x0C: return num(0.001 * A * B, "Ω")
        case 0x0D: return num((B - 127) * 0.001 * A, "mm")
        case 0x0E: return num(0.005 * A * B, "bar")
        case 0x0F: return num(0.01 * A * B, "ms")
        case 0x10: return txt(bits(bi & ai), "binary")
        case 0x11: return txt(ascii([ai, bi]))
        case 0x12: return num(0.04 * A * B, "mbar")
        case 0x13: return num(0.01 * A * B, "l")
        case 0x14: return num(A * (B - 128) / 128, "%")
        case 0x15: return num(0.001 * A * B, "V")
        case 0x16: return num(0.001 * A * B, "ms")
        case 0x17: return num(B / 256 * A, "%")
        case 0x18: return num(0.001 * A * B, "A")
        case 0x19: return num(B * 1.421 + A / 182, "g/s")
        case 0x1A: return num(B - A, "°C")
        case 0x1B: return num(abs(B - 128) * 0.01 * A, B < 128 ? "° ATDC" : "° BTDC")
        case 0x1C: return num(B - A, "")
        case 0x1D: return txt(bi < ai ? "Map 1" : "Map 2")
        case 0x1E: return num(B / 12 * A, "°KW")
        case 0x1F: return num(B / 2560 * A, "")
        case 0x20: return num(sB, "")
        case 0x21: return num(ai == 0 ? 100 * B : 100 * B / A, "%")
        case 0x22: return num((B - 128) * 0.01 * A, "kW")
        case 0x23: return num(0.01 * A * B, "l/h")
        case 0x24: return num(A * 2560 + B * 10, "km")
        case 0x25: return txt(String(format: "%02X %02X", ai, bi), "hex")
        case 0x26: return num((B - 128) * 0.001 * A, "°KW")
        case 0x27: return num(B / 256 * A, "mg/h")
        case 0x28: return num(B * 0.1 + 25.5 * A - 400, "A")
        case 0x29: return num(B + 255 * A, "Ah")
        case 0x2A: return num(B * 0.1 + 25.5 * A - 400, "kW")
        case 0x2B: return num(B * 0.1 + 25.5 * A, "V")
        case 0x2C: return txt(String(format: "%02d:%02d", ai, bi), "hh:mm")
        case 0x2D: return num(0.1 * A * B / 100, "")
        case 0x2E: return num((A * B - 3200) * 0.0027, "°KW")
        case 0x2F: return num((B - 128) * A, "ms")
        case 0x30: return num(B + 255 * A, "")
        case 0x31: return num(B / 4 * A * 0.1, "mg/h")
        case 0x32: return num(ai == 0 ? (B - 128) / 0.01 : (B - 128) / (0.01 * A), "mbar")
        case 0x33: return num((B - 128) / 255 * A, "mg/h")
        case 0x34: return num(B * 0.02 * A - A, "Nm")
        case 0x35: return num((B - 128) * 1.4222 + 0.006 * A, "g/s")
        case 0x36: return num(u16, "count")
        case 0x37: return num(A * B / 200, "s")
        case 0x38: return num(u16, "WSC")
        case 0x39: return num(u16 + 65536, "WSC")
        case 0x3A: return num(bi > 128 ? 1.0225 * (256 - B) : 1.0225 * B, "/s")
        case 0x3B: return num(u16 / 32768, "")
        case 0x3C: return num(u16 * 0.01, "s")
        case 0x3D: return num(ai == 0 ? B - 128 : (B - 128) / A, "")
        case 0x3E: return num(0.256 * A * B, "s")
        case 0x40: return num(A + B, "Ω")
        case 0x41: return num(0.01 * A * (B - 127), "mm")
        case 0x42: return num(A * B / 511.12, "V")
        case 0x43: return num(640 * A + 2.5 * B, "°")
        case 0x44: return num(u16 / 7.365, "°/s")
        case 0x45: return num(u16 * 0.3254, "bar")
        case 0x46: return num(u16 * 0.192, "m/s²")
        case 0x47: return num(A * B, "cm")
        case 0x48: return num((255 * A + B * (211 - A)) / 4080, "V")
        case 0x49: return num(0.01 * A * B, "Ω")
        case 0x4A: return num(0.1 * A * B, "months")
        case 0x4B: return txt(String(format: "%05d", Int(u16)), "fault code")
        case 0x4C: return num(255 * A + B, "kΩ")
        case 0x4D: return num((255 * A + 60 * B) / 4080, "V")
        case 0x4E: return num(sB * 1.819, "/s")
        case 0x4F: return num(B, "channel")
        case 0x50: return num(u16 / 100, "kΩ")
        case 0x51: return num(s16 * 0.04375, "°")
        case 0x52: return num(s16 * 0.00981, "m/s²")
        case 0x53: return num(s16 * 0.01, "bar")
        case 0x54: return num(s16 * 0.0973, "m/s²")
        case 0x55: return num(s16 * 0.002865, "°/s")
        case 0x56: return num(0.1 * A * B, "A")
        case 0x57: return num(A * (B - 128) * 0.1, "°/s")
        case 0x58: return num(0.01 * A * B, "kΩ")
        case 0x59: return num(u16, "h")
        case 0x5A: return num(0.1 * A * B, "kg")
        case 0x5B: return num(A * (B - 128) * 0.1, "°")
        case 0x5C: return num(A * B, "km")
        case 0x5D: return num((B - 128) * A * 0.001, "Nm")
        case 0x5E: return num(A * (B - 128) * 0.1, "Nm")
        case 0x60: return num(0.1 * A * B, "mbar")
        case 0x61: return num((B - A) * 5, "°C")
        case 0x63: return num(s16, "")
        case 0x64: return num(0.1 * A * B, "bar")
        case 0x67: return num(A + 0.05 * B, "V")
        case 0x6A: return num((B - 128) * A * 0.1, "km/h")
        case 0x6B: return txt(String(format: "%02X %02X", ai, bi), "hex")
        case 0x73: return num(s16, "W")
        case 0x74: return num(s16, "rpm")
        case 0x75: return num((B - 64) * A * 0.01, "°C")
        case 0x77: return num(0.01 * A * B, "%")
        case 0x80: return num(A * B, "rpm")
        case 0x81: return num(A * B / 256, "%")
        case 0x85: return num(A * B / 256, "V")
        case 0x86: return num(A * B, "km/h")
        case 0x89: return num(0.01 * A * B, "ms")
        case 0x8A: return num(0.001 * A * B, "V")
        case 0x8F: return num((B - 128) * A * 0.01, "°")
        case 0x92: return num(1 + (B - 128) * A * 0.0001, "λ")
        case 0x95: return num((B - 100) * A * 0.1, "°C")
        case 0x9F: return num(((B - 127) * 256 + A) * 0.1, "°C")
        case 0xAF: return num(0.005 * A * B, "bar")
        default:
            return txt(String(format: "%02X %02X", ai, bi), String(format: "type %02X", t))
        }
    }

    static func bits(_ v: UInt8) -> String {
        let s = String(v, radix: 2)
        return String(repeating: "0", count: max(0, 8 - s.count)) + s
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e7 { return String(format: "%.0f", v) }
        if abs(v) >= 100 { return String(format: "%.1f", v) }
        if abs(v) >= 10 { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
    }
}

// MARK: - Page

struct MeasuringBlocksView: View {
    @EnvironmentObject var s: VehicleSession
    @AppStorage("blocksAddress") private var address = 1
    @AppStorage("blocksGroups") private var groupsText = "1"

    private var groups: [UInt8] {
        var seen = Set<Int>()
        return groupsText.split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Int($0) }.filter { (0...255).contains($0) && seen.insert($0).inserted }
            .prefix(3).map { UInt8($0) }
    }

    private var addresses: [UInt8] {
        Array(Set(TP20.names.keys).union(s.tp20Reports.map(\.address))).sorted()
    }

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "Measuring Blocks",
                               subtitle: "Live values from older VW, Audi, Skoda and Seat modules (TP2.0), read the way VCDS reads them — read-only")
                    if !s.isCAN || s.protocolName.contains("29-bit") {
                        Label("Measuring blocks need an older VW-group car on 11-bit CAN (about 2004–2014).", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 14) {
                                Picker("Module", selection: $address) {
                                    ForEach(addresses, id: \.self) { a in
                                        Text(String(format: "%02X – %@", Int(a), TP20.names[a] ?? "Module")).tag(Int(a))
                                    }
                                }
                                .frame(width: 280)
                                TextField("Groups, e.g. 1, 2, 4", text: $groupsText)
                                    .textFieldStyle(.roundedBorder).frame(width: 160)
                                Spacer()
                                if s.blocksLive {
                                    Button("Stop", role: .destructive) { s.stopBlocks() }
                                } else {
                                    Button("Read once") { Task { await s.readBlocks(address: UInt8(address), groups: groups, live: false) } }
                                        .disabled(s.busy != nil || groups.isEmpty || !s.isCAN || s.protocolName.contains("29-bit"))
                                    Button("Go live") { Task { await s.readBlocks(address: UInt8(address), groups: groups, live: true) } }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(s.busy != nil || groups.isEmpty || !s.isCAN || s.protocolName.contains("29-bit"))
                                }
                            }
                            Text("Up to 3 groups (000–255), like VCDS. What each group holds is set by the module — for example the Bugatti VCDS screenshot showed oil pressures in module 02, group 004. Groups a module doesn't have come back as \"not available\".")
                                .font(.caption).foregroundStyle(.secondary)
                            if let st = s.blockStatus { Text(st).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    ForEach(s.blockReadings) { g in GroupCard(reading: g, minMax: s.blockMinMax, address: s.blockAddress) }
                    GatewayListCard()
                    CamTimingCard()
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Explore a module").font(.headline)
                                Spacer()
                                Button("Instruments (17)") { Task { await s.exploreBlocks(address: 0x17) } }
                                Button("Gateway (19)") { Task { await s.exploreBlocks(address: 0x19) } }
                                Button("ABS (03)") { Task { await s.exploreBlocks(address: 0x03) } }
                                Button("Selected module") { Task { await s.exploreBlocks(address: UInt8(address)) } }
                                    .buttonStyle(.borderedProminent)
                            }
                            .disabled(s.busy != nil || !s.isCAN || s.protocolName.contains("29-bit"))
                            Text("Reads groups 001–040 once and lists every group that has data, so you can find where a module keeps its mileage, service countdowns, battery data and wheel speeds. On VWs the instrument cluster (17) usually holds mileage and service info, and the gateway (19) often holds battery monitoring. Mileage found here is compared with the car's odometer on the Pre-Purchase Check.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let p = s.explorerProgress {
                                HStack {
                                    ProgressView(value: p)
                                    Button("Stop", role: .destructive) { s.stopBlocks() }
                                }
                            }
                            if !s.moduleOdometers.isEmpty {
                                ForEach(s.moduleOdometers.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                    Label("Mileage in \(k): \(UnitKind.distance.format(v, s.units))", systemImage: "road.lanes")
                                        .font(.callout)
                                }
                            }
                        }
                    }
                    ForEach(s.explorerResults) { g in GroupCard(reading: g, minMax: [:], address: s.explorerAddress) }
                    if s.blockLogCount > 0 {
                        HStack {
                            Text("\(s.blockLogCount) samples logged").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Save log as CSV…") { s.exportBlockCSV() }
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct GroupCard: View {
    let reading: GroupReading
    let minMax: [String: (Double, Double)]
    var address: UInt8? = nil
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Group \(reading.groupText)").font(.headline)
                if let e = reading.error {
                    Text(e).foregroundStyle(.secondary)
                } else if reading.fields.isEmpty {
                    Text("Empty group").foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(reading.fields) { f in
                            FieldView(field: f, group: reading.group, address: address,
                                      minMax: minMax["\(reading.group).\(f.index)"])
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

/// One measuring-block field, with a name the owner can set (saved per car and in the module library).
private struct FieldView: View {
    @EnvironmentObject var s: VehicleSession
    let field: BlockField
    let group: UInt8
    let address: UInt8?
    let minMax: (Double, Double)?
    @State private var editing = false
    @State private var draft = ""

    private var label: String? { address.flatMap { s.blockLabel(address: $0, group: group, field: field.index) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label ?? "Field \(field.index + 1)").font(.caption).foregroundStyle(label == nil ? Color.secondary : Color.primary)
                if address != nil {
                    Button { draft = label ?? ""; editing = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).font(.caption2)
                        .help("Name this field (e.g. Oil pressure) — saved for this car and shared through the module library")
                        .popover(isPresented: $editing) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Name field \(field.index + 1) of group \(String(format: "%03d", Int(group)))").font(.headline)
                                TextField("e.g. Oil pressure", text: $draft).textFieldStyle(.roundedBorder).frame(width: 240)
                                    .onSubmit(save)
                                HStack {
                                    Button("Clear") { draft = ""; save() }
                                    Spacer()
                                    Button("Save", action: save).buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(14)
                        }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(field.text).font(.title2.monospacedDigit().bold())
                Text(field.unit).foregroundStyle(.secondary)
            }
            if let mm = minMax, field.value != nil {
                Text("min \(VAGBlocks.format(mm.0)) · max \(VAGBlocks.format(mm.1))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(field.rawText).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
    }

    private func save() {
        guard let a = address else { return }
        s.setBlockLabel(address: a, group: group, field: field.index, label: draft)
        editing = false
    }
}

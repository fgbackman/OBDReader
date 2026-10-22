import SwiftUI
import AppKit
import UniformTypeIdentifiers

// CAN Bus Listener page: listen to the car's broadcast traffic and decode it with a DBC file.
// Listen-only — the adapter is put in monitor mode and nothing is sent to the car.

struct BusListenerView: View {
    @EnvironmentObject var s: VehicleSession
    @ObservedObject private var lib = DBCLibrary.shared
    @AppStorage("busDBCName") private var dbcName = ""
    @State private var only: CANKey?
    @State private var search = ""
    @State private var warningsOnly = false
    @State private var hideUnknown = false
    @State private var expanded: Set<CANKey> = []
    @State private var matches: [DBCLibrary.Match]?
    @State private var ranking = false
    @State private var loading = false
    @State private var note: String?

    private var keys: [CANKey] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return s.busStats.keys.sorted().filter { k in
            let msg = s.busDBC?.messages[k]
            if hideUnknown && msg == nil { return false }
            guard !q.isEmpty else { return true }
            if k.text.lowercased().contains(q) { return true }
            guard let msg else { return false }
            return msg.name.lowercased().contains(q) || msg.signals.contains { $0.name.lowercased().contains(q) }
        }
    }

    private var knownCount: Int {
        guard let d = s.busDBC else { return 0 }
        return s.busStats.keys.filter { d.messages[$0] != nil }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "CAN Bus Listener",
                           subtitle: "Hear what the car's computers broadcast and decode it with a DBC file — listen-only")
                aboutCard
                dbcCard
                controlsCard
                if !s.busStats.isEmpty {
                    if warningsOnly { warningsCard } else { messagesCard }
                }
            }
            .padding(24)
        }
        .task { await loadSelected() }
        .onChange(of: dbcName) { _, _ in Task { await loadSelected() } }
    }

    // MARK: Cards

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Listen-only: the adapter is switched to monitor mode and sends nothing to the car.", systemImage: "ear")
                    .font(.callout.weight(.medium))
                Text("Works where the car puts its internal traffic on the OBD port. Many cars have a gateway that passes only diagnostic requests to the port; on those you'll hear nothing. A DBC file says where each value sits in each message; the brand files in the CSS Electronics collection are mostly reverse-engineered, so check values against the dashboard. Cheap ELM327 clones often can't keep up with a busy 500 kbit/s bus (\"buffer full\"); an OBDLink adapter copes much better, and listening to one message at a time helps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dbcCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("DBC file").font(.headline)
                    Picker("", selection: $dbcName) {
                        Text("None").tag("")
                        ForEach(lib.files, id: \.lastPathComponent) { Text($0.lastPathComponent).tag($0.lastPathComponent) }
                    }
                    .frame(width: 340)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Add DBC files or folders…") { addFiles() }
                    if !dbcName.isEmpty {
                        Button("Remove") { lib.remove(dbcName); dbcName = "" }
                    }
                }
                if let d = s.busDBC {
                    Text("\(d.messages.count) messages, \(d.signalCount) signals" + (d.duplicateIDs > 0 ? " (\(d.duplicateIDs) duplicate IDs ignored — the first definition is used)" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                } else if lib.files.isEmpty {
                    Text("Add DBC files to decode what you hear — you can pick a whole folder (for example your brand-can-dbc folder) and every .dbc inside is added.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(ranking ? "Checking…" : "Which DBC fits this car?") { Task { await rank() } }
                        .disabled(s.busStats.isEmpty || lib.files.isEmpty || ranking)
                    Text("Compares the IDs heard so far with every DBC you've added.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let matches {
                    if matches.isEmpty {
                        Text("None of your DBC files describe the IDs heard on this car.").foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                            ForEach(matches.prefix(6)) { m in
                                GridRow {
                                    Text(m.name).lineLimit(1)
                                    Text("\(m.known) of \(m.heard) IDs").monospacedDigit()
                                    Text("\(m.lengthOK) with matching length").font(.caption).foregroundStyle(.secondary)
                                    Button("Use") { dbcName = m.name }.disabled(dbcName == m.name)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var controlsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if s.busListening {
                        Button("Stop", role: .destructive) { s.stopBusListen() }
                    } else {
                        Button("Start listening") { Task { await s.startBusListen(only: only) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!s.isConnected || !s.isCAN || s.busy != nil)
                    }
                    Picker("Listen to", selection: $only) {
                        Text("All messages").tag(CANKey?.none)
                        ForEach(s.busStats.keys.sorted(), id: \.self) { k in
                            Text(k.text + (s.busDBC?.messages[k].map { " \($0.name)" } ?? "")).tag(CANKey?.some(k))
                        }
                    }
                    .frame(width: 280)
                    .disabled(s.busListening)
                    Spacer()
                    Button("Clear") { s.clearBus(); matches = nil }.disabled(s.busListening || s.busStats.isEmpty)
                }
                HStack {
                    Toggle("Warning lights only", isOn: $warningsOnly)
                    Toggle("Hide IDs not in the DBC", isOn: $hideUnknown).disabled(s.busDBC == nil)
                    TextField("Search ID, message or signal", text: $search).frame(width: 240)
                    Spacer()
                    Button("Open log…") { s.openBusLog() }.disabled(s.busListening)
                    Button("Save log…") { s.saveBusLog() }.disabled(s.busLog.isEmpty)
                    Button("Save decoded…") { s.saveBusDecoded() }.disabled(s.busLog.isEmpty || s.busDBC == nil)
                }
                if !s.isConnected {
                    Text("Connect to the adapter to listen — or open a log saved earlier to decode it without the car.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !s.isCAN {
                    Text("This car talks over an older (non-CAN) protocol, so there's no CAN traffic to listen to.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !s.busStats.isEmpty {
                    Text(statsLine).font(.caption).foregroundStyle(.secondary)
                }
                if let st = s.busStatus { Text(st).font(.caption).foregroundStyle(.orange) }
                if s.busOverflows > 0 {
                    Text("The adapter's buffer filled up \(s.busOverflows)× and dropped frames, so rates are undercounted. Listening to one message at a time avoids this.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var statsLine: String {
        var parts = ["\(s.busFrames) frames", "\(s.busStats.count) IDs"]
        if s.busDBC != nil { parts.append("\(knownCount) described by the DBC") }
        if let src = s.busSource { parts.append(src == "Live" ? String(format: "%.0f s listening", s.busSeconds) : "from \(src)") }
        return parts.joined(separator: " · ")
    }

    private var messagesCard: some View {
        Card {
            LazyVStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ID").frame(width: 80, alignment: .leading)
                    Text("Message").frame(width: 230, alignment: .leading)
                    Text("Rate").frame(width: 70, alignment: .trailing)
                    Text("Data (orange bytes have changed)").padding(.leading, 12)
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(keys, id: \.self) { k in
                    if let st = s.busStats[k] {
                        BusRow(key: k, stat: st, msg: s.busDBC?.messages[k], seconds: s.busSeconds,
                               ranges: s.busRanges, expanded: binding(k))
                        Divider()
                    }
                }
            }
        }
    }

    private var warningsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Warning-light signals").font(.headline)
                if let d = s.busDBC {
                    let rows = s.busStats.keys.sorted().flatMap { k -> [WarnRow] in
                        guard let m = d.messages[k], let data = s.busStats[k]?.data else { return [] }
                        return m.decode(data).filter { WarningSignals.matches($0.signal.name) }.map { x in
                            WarnRow(name: x.signal.name, value: x.signal.choice(data) ?? VAGBlocks.format(x.value),
                                    source: "\(k.text) \(m.name)", on: x.value != 0)
                        }
                    }
                    if rows.isEmpty {
                        Text("No lamp or warning signals in the messages heard so far.").foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                            ForEach(rows) { r in
                                GridRow {
                                    Image(systemName: r.on ? "lightbulb.max.fill" : "lightbulb")
                                        .foregroundStyle(r.on ? .orange : .secondary)
                                    Text(r.name).monospaced()
                                    Text(r.value).monospacedDigit().foregroundStyle(r.on ? .orange : .primary)
                                    Text(r.source).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Picked by name (lamp, light, warn, Lampe, Leuchte …). Usually 1 means on — compare with the dashboard before trusting a DBC you haven't checked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Pick a DBC file first.").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Helpers

    private func binding(_ k: CANKey) -> Binding<Bool> {
        Binding(get: { expanded.contains(k) },
                set: { if $0 { expanded.insert(k) } else { expanded.remove(k) } })
    }

    private func loadSelected() async {
        guard !dbcName.isEmpty else { s.busDBC = nil; return }
        if s.busDBC?.name == dbcName { return }
        loading = true
        let f = await lib.file(dbcName)
        loading = false
        if f == nil { note = "Couldn't read \(dbcName) as a DBC file." }
        s.busDBC = f
        s.recomputeBusRanges()
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose .dbc files, or folders containing them"
        guard panel.runModal() == .OK else { return }
        let n = lib.add(panel.urls)
        note = n == 0 ? "No .dbc files found there." : "Added \(n) DBC file\(n == 1 ? "" : "s")."
        matches = nil
        if dbcName.isEmpty, let first = lib.files.first { dbcName = first.lastPathComponent }
    }

    private func rank() async {
        ranking = true
        let heard = s.busStats.mapValues { $0.data.count }
        matches = await lib.rank(heard: heard)
        ranking = false
    }
}

private struct WarnRow: Identifiable {
    let name: String
    let value: String
    let source: String
    let on: Bool
    var id: String { source + "." + name }
}

private struct BusRow: View {
    let key: CANKey
    let stat: BusStat
    let msg: DBCMessage?
    let seconds: Double
    let ranges: [String: (Double, Double)]
    @Binding var expanded: Bool

    private var rate: String {
        guard seconds > 0.2 else { return "—" }
        let hz = Double(stat.count) / seconds
        return hz >= 10 ? String(format: "%.0f Hz", hz) : String(format: "%.1f Hz", hz)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let msg {
                let decoded = msg.decode(stat.data)
                if decoded.isEmpty {
                    Text("The frame is shorter than this DBC expects (\(stat.data.count) of \(msg.length) bytes) — probably a different car.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    ForEach(Array(decoded.enumerated()), id: \.offset) { _, d in
                        let sig = d.signal
                        let v = d.value
                        let r = ranges[key.text + "." + sig.name]
                        let outside = Self.outside(sig, v)
                        GridRow {
                            Text(sig.name).monospaced().help(sig.comment ?? "")
                            Text(sig.choice(stat.data) ?? VAGBlocks.format(v))
                                .monospacedDigit().foregroundStyle(outside ? .orange : .primary)
                            Text(sig.unit).foregroundStyle(.secondary)
                            Text(r.map { "\(VAGBlocks.format($0.0)) – \(VAGBlocks.format($0.1))" } ?? "")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 20)
                if decoded.contains(where: { Self.outside($0.signal, $0.value) }) {
                    Text("Orange values are outside the range the DBC gives — the file may not match this car.")
                        .font(.caption).foregroundStyle(.orange).padding(.leading, 20)
                }
            } else {
                Text("Not in the selected DBC. Orange bytes have changed while listening — those are the ones carrying live data.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            }
        } label: {
            HStack(spacing: 0) {
                Text(key.text).monospaced().frame(width: 80, alignment: .leading)
                Text(msg?.name ?? "—").lineLimit(1).frame(width: 230, alignment: .leading)
                    .foregroundStyle(msg == nil ? .secondary : .primary)
                Text(rate).monospacedDigit().frame(width: 70, alignment: .trailing)
                HStack(spacing: 5) {
                    ForEach(Array(stat.data.enumerated()), id: \.offset) { i, b in
                        Text(String(format: "%02X", b)).monospaced()
                            .foregroundStyle(i < stat.changed.count && stat.changed[i] != 0 ? .orange : .secondary)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    /// Outside the DBC's [min|max]. Many DBCs write [0|0] to mean "no range", so that's ignored.
    static func outside(_ s: DBCSignal, _ v: Double) -> Bool {
        guard let lo = s.minimum, let hi = s.maximum, hi > lo else { return false }
        let slack = max(abs(s.factor), 1e-9)
        return v < lo - slack || v > hi + slack
    }
}

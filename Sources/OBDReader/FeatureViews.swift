import SwiftUI
import Charts
import AppKit

// MARK: - Self-tests (Mode 06)

struct TestsView: View {
    @EnvironmentObject var s: VehicleSession
    @State private var showAll = false

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "Self-Tests",
                               subtitle: "The car's own test results, with the limits it judges itself against")
                    if !s.legacyTests.isEmpty {
                        LegacyTestsSection(tests: s.legacyTests)
                    } else if s.testsSupported == false {
                        Card { Text("This car didn't report self-test results.").foregroundStyle(.secondary) }
                    } else if s.tests.isEmpty {
                        Text("No results yet — press Rescan.").foregroundStyle(.secondary)
                    } else {
                        summary
                        misfireChart
                        Toggle("Show passing tests too", isOn: $showAll).toggleStyle(.switch)
                        ForEach(groups, id: \.0) { group in
                            Text(group.0).font(.headline).padding(.top, 6)
                            ForEach(group.1) { TestRow(t: $0) }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var summary: some View {
        let failed = s.tests.filter { !$0.passed }.count
        let near = s.tests.filter(\.nearLimit).count
        let ok = s.tests.filter { $0.hasLimits && $0.passed && !$0.nearLimit }.count
        return HStack(spacing: 12) {
            StatTile(label: "Failed", value: "\(failed)", color: failed > 0 ? .red : .secondary)
            StatTile(label: "Close to limit", value: "\(near)", color: near > 0 ? .orange : .secondary)
            StatTile(label: "Passing", value: "\(ok)", color: .green)
        }
    }

    @ViewBuilder private var misfireChart: some View {
        let rows = s.tests.filter { $0.cylinder != nil && $0.tid == 0x0C }.sorted { $0.cylinder! < $1.cylinder! }
        let ecus = Set(rows.map { $0.ecu }).count
        let expected = s.profile?.cylinders
        if !rows.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Misfires by cylinder (last drive)").font(.headline)
                    Chart(rows) { t in
                        BarMark(x: .value("Cylinder", "\(t.cylinder!)"), y: .value("Misfires", t.raw))
                            .foregroundStyle(t.raw >= 5 ? Color.orange : Color.accentColor)
                    }
                    .frame(height: 140)
                    Text(chartCaption(count: rows.count, ecus: ecus, expected: expected))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chartCaption(count: Int, ecus: Int, expected: Int?) -> String {
        var t = "\(count) cylinder\(count == 1 ? "" : "s") reported"
        if ecus > 1 { t += " by \(ecus) engine computers (the second one's cylinders are numbered after the first's)" }
        if let n = expected, n > count {
            t += ". This \(s.profile?.engineLayout ?? "engine") has \(n) — standard OBD-II names at most 12 per computer; Diagnosis estimates the rest as a group."
        } else {
            t += "."
        }
        return t
    }

    private var groups: [(String, [TestResult])] {
        let list = s.tests.filter { !$0.isMisfireCounter && (showAll || !$0.passed || $0.nearLimit) }
        let names = list.map(\.monitorName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return names.map { n in (n, list.filter { $0.monitorName == n }) }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(color)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TestRow: View {
    let t: TestResult
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(t.testName).font(.body.weight(.medium))
                    Spacer()
                    Text(t.formatted(t.scaled.value)).font(.body.monospacedDigit())
                }
                if t.hasLimits {
                    LimitBar(raw: t.raw, lo: t.rawMin, hi: t.rawMax, color: color)
                    HStack {
                        Text("min \(t.formatted(t.scaled.min))")
                        Spacer()
                        Text("max \(t.formatted(t.scaled.max))")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var color: Color { !t.passed ? .red : t.nearLimit ? .orange : .green }
    private var icon: String { !t.passed ? "xmark.circle.fill" : t.nearLimit ? "exclamationmark.circle.fill" : "checkmark.circle.fill" }
}

/// Where the value sits between its limits.
struct LimitBar: View {
    let raw: Int, lo: Int, hi: Int
    let color: Color
    var body: some View {
        GeometryReader { g in
            let span = Double(max(hi - lo, 1))
            let pos = min(1.08, max(-0.08, Double(raw - lo) / span))
            let inset = g.size.width * 0.08
            let usable = g.size.width - inset * 2
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
                Capsule().fill(Color.green.opacity(0.25)).frame(width: usable, height: 6).offset(x: inset)
                Circle().fill(color).frame(width: 12, height: 12)
                    .offset(x: inset + usable * pos - 6)
            }
            .frame(height: 12)
        }
        .frame(height: 12)
    }
}

// MARK: - Smog check

struct SmogView: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "Smog Check", subtitle: "Would the OBD part of a California Smog Check pass right now?")
                    if let region = s.profile?.region, region != "California" {
                        Card {
                            Text(region == CarProfile.regionUK
                                 ? "This car is set to England / UK, where the MOT applies instead. On petrol cars first used from 1 July 2003, an engine warning light that's on or doesn't work is a major fault (MOT inspection manual, section 8). The California result below is for reference."
                                 : region == "Florida"
                                 ? "This car is set to Florida, which has had no emissions test since 2000. The California result below is for reference — useful if the car will ever be registered there."
                                 : "This car is set to another US state. Emissions testing rules vary by state; the California result below is for reference.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let v = s.smog {
                        Card {
                            HStack(spacing: 14) {
                                Image(systemName: v.result == .pass ? "checkmark.seal.fill"
                                      : v.result == .fail ? "xmark.seal.fill" : "questionmark.circle.fill")
                                    .font(.system(size: 40))
                                    .foregroundStyle(v.result == .pass ? Color.green : v.result == .fail ? Color.red : Color.secondary)
                                VStack(alignment: .leading) {
                                    Text(v.result.rawValue).font(.title.bold())
                                    if let p = s.profile {
                                        Text("\(p.nickname) · model year \(p.modelYear.map { String($0) } ?? "unknown") · \(p.isDiesel ? "diesel" : "gasoline")")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if !v.reasons.isEmpty {
                            Text("Why it would fail").font(.headline)
                            ForEach(v.reasons, id: \.self) { Label($0, systemImage: "xmark.circle").foregroundStyle(.red) }
                        }
                        if !v.notes.isEmpty {
                            Text("Notes").font(.headline).padding(.top, 4)
                            ForEach(v.notes, id: \.self) { Label($0, systemImage: "info.circle").foregroundStyle(.secondary) }
                        }
                        Text("Based on BAR's published OBD fail criteria. Model year and fuel type come from the Garage.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ReadinessView.MonitorList()
                }
                .padding(24)
            }
        }
    }
}

extension ReadinessView {
    /// Compact list of readiness monitors, reused on the Smog Check page.
    struct MonitorList: View {
        @EnvironmentObject var s: VehicleSession
        var body: some View {
            if let r = s.readiness, !r.monitors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Readiness monitors").font(.headline).padding(.top, 8)
                    ForEach(r.monitors) { m in
                        HStack {
                            Image(systemName: m.complete ? "checkmark.circle.fill" : "clock.fill")
                                .foregroundStyle(m.complete ? .green : .orange)
                            Text(m.name)
                            Spacer()
                            Text(m.complete ? "Complete" : "Not ready").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Battery test

struct BatteryTestView: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "Battery Test", subtitle: "Resting voltage, cranking dip and charging voltage")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(instruction).font(.title3.weight(.medium))
                            HStack {
                                switch s.crankPhase {
                                case .resting, .waitingForStart, .running:
                                    ProgressView().controlSize(.small)
                                    Button("Cancel") { s.cancelCrankTest() }
                                default:
                                    Button("Start test") { Task { await s.runCrankTest() } }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(s.busy != nil)
                                }
                            }
                            if case .failed(let msg) = s.crankPhase {
                                Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                    }
                    if !s.crankSamples.isEmpty {
                        Card {
                            Chart(s.crankSamples) { p in
                                LineMark(x: .value("Seconds", p.t), y: .value("Volts", p.volts))
                                    .interpolationMethod(.linear)
                                RuleMark(y: .value("Weak", 9.6))
                                    .foregroundStyle(.red.opacity(0.5))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            }
                            .chartYScale(domain: 8.0...15.0)
                            .chartYAxisLabel("V")
                            .chartXAxisLabel("seconds")
                            .frame(height: 220)
                        }
                    }
                    if let r = s.crankResult {
                        HStack(spacing: 12) {
                            ResultTile(title: "Resting", volts: r.rest, verdict: r.restVerdict)
                            ResultTile(title: "Lowest while cranking", volts: r.crankMin, verdict: r.crankVerdict)
                            ResultTile(title: "Running", volts: r.running, verdict: r.runningVerdict)
                        }
                    }
                    Text("Voltage is measured at the diagnostic port, so it reads a little below the battery terminals. Results are a guide — a shop load test is the final word.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
    }

    private var instruction: String {
        switch s.crankPhase {
        case .idle, .done, .failed:
            return "Engine off, ignition on. Press Start, wait for the prompt, then start the engine."
        case .resting: return "Measuring resting voltage — keep the engine off…"
        case .waitingForStart: return s.useSimulator ? "Start the engine now (the simulator will do it for you)…" : "Start the engine now."
        case .running: return "Engine started — measuring charging voltage…"
        }
    }
}

struct ResultTile: View {
    let title: String
    let volts: Double?
    let verdict: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(volts.map { String(format: "%.2f V", $0) } ?? "—").font(.title2.monospacedDigit().bold())
                Text(verdict).font(.callout)
            }
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var s: VehicleSession
    @EnvironmentObject var garage: GarageStore
    @State private var selectedVIN: String?
    @State private var trendPID: UInt8 = 0x07

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "History", subtitle: "Every scan saved per car, so changes over time stand out")
                if garage.profiles.isEmpty {
                    Text("No scans saved yet. Connect and scan a car.").foregroundStyle(.secondary)
                } else {
                    Picker("Car", selection: Binding(get: { vin }, set: { selectedVIN = $0 })) {
                        ForEach(garage.profiles) { Text($0.nickname).tag($0.vin) }
                    }
                    .frame(maxWidth: 360)
                    let records = garage.history(vin)
                    if records.isEmpty {
                        Text("No scans for this car yet.").foregroundStyle(.secondary)
                    } else {
                        trend(records)
                        codeTimeline(records)
                        Text("Scans").font(.headline)
                        ForEach(records.reversed()) { r in ScanRow(r: r) }
                    }
                }
            }
            .padding(24)
        }
    }

    private var vin: String { selectedVIN ?? s.profile?.vin ?? garage.profiles.first?.vin ?? "" }

    @ViewBuilder private func trend(_ records: [ScanRecord]) -> some View {
        let candidates: [UInt8] = [0x07, 0x09, 0x06, 0x08, 0x05, 0x42, 0x0F, 0x10, 0x31]
        let points = records.compactMap { r in r.snapshot[trendPID].map { (r.date, $0) } }
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Trend").font(.headline)
                    Spacer()
                    Picker("", selection: $trendPID) {
                        ForEach(candidates, id: \.self) { pid in Text(PIDs.def(pid)?.name ?? "").tag(pid) }
                    }
                    .frame(width: 260)
                }
                if points.count < 2 {
                    Text("Needs at least two scans with this reading.").foregroundStyle(.secondary).frame(height: 60)
                } else if let def = PIDs.def(trendPID) {
                    Chart(points.indices, id: \.self) { i in
                        let v = def.present(points[i].1, s.units).0
                        LineMark(x: .value("Date", points[i].0), y: .value(def.name, v))
                        PointMark(x: .value("Date", points[i].0), y: .value(def.name, v))
                    }
                    .chartYAxisLabel(def.unitLabel(s.units))
                    .frame(height: 180)
                }
            }
        }
    }

    @ViewBuilder private func codeTimeline(_ records: [ScanRecord]) -> some View {
        let codes = Set(records.flatMap { $0.codes.map(\.code) }).sorted()
        if !codes.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Codes over time").font(.headline)
                    ForEach(codes, id: \.self) { code in
                        let seen = records.filter { $0.codes.contains { $0.code == code } }
                        HStack {
                            Text(code).font(.body.monospaced().bold()).frame(width: 70, alignment: .leading)
                            Text(DTCDatabase.describe(code)).lineLimit(1)
                            Spacer()
                            if let first = seen.first?.date, let last = seen.last?.date {
                                Text("first \(first.formatted(date: .abbreviated, time: .omitted)) · last \(last.formatted(date: .abbreviated, time: .omitted)) · \(seen.count)×")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ScanRow: View {
    let r: ScanRecord
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    Spacer()
                    if let v = r.smogVerdict { Text("Smog: \(v)").font(.caption).foregroundStyle(.secondary) }
                }
                Text(r.codes.isEmpty ? "No codes" : r.codes.map { "\($0.code) (\($0.kind.lowercased()))" }.joined(separator: ", "))
                if !r.failedTests.isEmpty { Text("Failed tests: \(r.failedTests.joined(separator: "; "))").font(.caption).foregroundStyle(.red) }
                if !r.nearLimitTests.isEmpty { Text("Near limit: \(r.nearLimitTests.joined(separator: "; "))").font(.caption).foregroundStyle(.orange) }
                if !r.incompleteMonitors.isEmpty { Text("Not ready: \(r.incompleteMonitors.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - AI explanation

struct AIExplainView: View {
    @EnvironmentObject var s: VehicleSession
    @State private var keyField = ""
    @State private var hasKey = !Keychain.load().isEmpty
    @State private var includeVIN = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "AI Explanation", subtitle: "Claude reads the full report and explains it in plain English")
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SecureField(hasKey ? "API key saved in Keychain" : "Anthropic API key (sk-ant-…)", text: $keyField)
                                .textFieldStyle(.roundedBorder)
                            Button(hasKey && keyField.isEmpty ? "Remove key" : "Save key") {
                                Keychain.save(keyField)
                                hasKey = !keyField.isEmpty
                                keyField = ""
                            }
                        }
                        HStack {
                            Picker("Model", selection: $s.aiModel) {
                                ForEach(AIExplainer.models, id: \.self) { Text($0).tag($0) }
                            }
                            .frame(maxWidth: 320)
                            Toggle("Include VIN", isOn: $includeVIN)
                        }
                        Text("The report (codes, readiness, self-tests, live snapshot) is sent to Anthropic's API using your own key. The VIN is left out unless you tick the box. Get a key at console.anthropic.com.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Explain my scan") { Task { await s.explainWithAI(includeVIN: includeVIN) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(s.aiBusy || s.lastScan == nil || !hasKey)
                            if s.aiBusy { ProgressView().controlSize(.small); Text("Asking Claude…").foregroundStyle(.secondary) }
                            if s.lastScan == nil { Text("Scan a car first.").foregroundStyle(.secondary) }
                        }
                        if let e = s.aiError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                }
                if !s.aiText.isEmpty {
                    Card {
                        Text(markdown(s.aiText)).textSelection(.enabled)
                    }
                    Text("AI explanations can be wrong. Confirm with a technician before replacing parts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Garage

struct GarageView: View {
    @EnvironmentObject var s: VehicleSession
    @EnvironmentObject var garage: GarageStore
    @State private var confirmDelete: CarProfile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Garage", subtitle: "One profile per car, recognised automatically by VIN")
                if garage.profiles.isEmpty {
                    Text("Cars appear here after their first scan.").foregroundStyle(.secondary)
                }
                ForEach(garage.profiles) { p in
                    ProfileCard(profile: p, isCurrent: p.vin == s.profile?.vin) { updated in
                        s.saveProfile(updated)
                    } onDelete: { confirmDelete = p }
                }
            }
            .padding(24)
        }
        .confirmationDialog("Delete this car and its scan history?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { p in
            Button("Delete \(p.nickname)", role: .destructive) { garage.delete(p.vin) }
        }
    }
}

struct ProfileCard: View {
    let profile: CarProfile
    let isCurrent: Bool
    let onSave: (CarProfile) -> Void
    let onDelete: () -> Void
    @State private var draft: CarProfile

    init(profile: CarProfile, isCurrent: Bool, onSave: @escaping (CarProfile) -> Void, onDelete: @escaping () -> Void) {
        self.profile = profile; self.isCurrent = isCurrent; self.onSave = onSave; self.onDelete = onDelete
        _draft = State(initialValue: profile)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "car.fill").foregroundStyle(isCurrent ? Color.green : Color.secondary)
                    TextField("Nickname", text: $draft.nickname).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    if isCurrent { Text("Connected").font(.caption.bold()).foregroundStyle(.green) }
                    Spacer()
                    Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("VIN").foregroundStyle(.secondary)
                        Text(profile.vin).font(.body.monospaced()).textSelection(.enabled)
                    }
                    if let m = VINDecoder.manufacturer(profile.vin) {
                        GridRow { Text("Make").foregroundStyle(.secondary); Text(m) }
                    }
                    GridRow {
                        Text("Model year").foregroundStyle(.secondary)
                        HStack {
                            TextField("year", value: $draft.modelYear, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 80)
                            Text("from VIN — correct it if wrong").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Fuel").foregroundStyle(.secondary)
                        Picker("", selection: $draft.isDiesel) {
                            Text("Gasoline").tag(false)
                            Text("Diesel").tag(true)
                        }
                        .pickerStyle(.segmented).frame(width: 200)
                    }
                    GridRow {
                        Text("Make / model").foregroundStyle(.secondary)
                        HStack {
                            TextField("make", text: Binding(get: { draft.make ?? VINDecoder.manufacturer(draft.vin) ?? "" },
                                                            set: { draft.make = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder).frame(width: 140)
                            TextField("model (e.g. Veyron)", text: Binding(get: { draft.model ?? "" },
                                                                           set: { draft.model = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder).frame(width: 160)
                        }
                    }
                    GridRow {
                        Text("Kept in").foregroundStyle(.secondary)
                        Picker("", selection: $draft.region) {
                            Text("Not set").tag(String?.none)
                            ForEach(CarProfile.regions, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .frame(width: 200)
                    }
                    GridRow {
                        Text("Engine").foregroundStyle(.secondary)
                        HStack {
                            Picker("", selection: $draft.engineLayout) {
                                Text("Not set").tag(String?.none)
                                ForEach(EngineLayout.all, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                            .frame(width: 140)
                            Text("numbers misfire counters across both engine computers").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Menu bar").foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { draft.menuBarPIDs.first ?? 0x0C },
                            set: { draft.menuBarPIDs = [$0] + draft.menuBarPIDs.dropFirst() })) {
                            ForEach(PIDs.all.filter(\.onDashboard)) { Text($0.name).tag($0.pid) }
                        }
                        .frame(width: 240)
                    }
                    GridRow {
                        Text("").foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { draft.menuBarPIDs.count > 1 ? draft.menuBarPIDs[1] : 0 },
                            set: { draft.menuBarPIDs = [draft.menuBarPIDs.first ?? 0x0C] + ($0 == 0 ? [] : [$0]) })) {
                            Text("— nothing —").tag(UInt8(0))
                            ForEach(PIDs.all.filter(\.onDashboard)) { Text($0.name).tag($0.pid) }
                        }
                        .frame(width: 240)
                    }
                    GridRow {
                        Text("Last seen").foregroundStyle(.secondary)
                        Text(profile.lastSeen.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                HStack {
                    Spacer()
                    Button("Save") { onSave(draft) }
                        .disabled(draft == profile)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onChange(of: profile) { _, new in draft = new }
    }
}

// MARK: - Trip computer

struct TripView: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        PageHeader(title: "Trip", subtitle: "Distance, fuel and economy while live data is running")
                        Spacer()
                        Button(s.isLive ? "Pause" : "Start") { if s.isLive { s.stopLive() } else { s.startLive() } }
                        Button("Reset trip") { s.resetTrip() }
                    }
                    let t = s.trip
                    let us = s.units == .us
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        BigStat(label: "Distance", value: us ? String(format: "%.2f mi", t.distanceKm * 0.621371) : String(format: "%.2f km", t.distanceKm))
                        BigStat(label: "Fuel used", value: us ? String(format: "%.2f gal", t.fuelL * 0.264172) : String(format: "%.2f L", t.fuelL))
                        BigStat(label: "Economy", value: us ? (t.mpg.map { String(format: "%.1f mpg", $0) } ?? "—")
                                                           : (t.litersPer100km.map { String(format: "%.1f L/100km", $0) } ?? "—"))
                        BigStat(label: "Average speed", value: us ? String(format: "%.0f mph", t.averageSpeedKmh * 0.621371) : String(format: "%.0f km/h", t.averageSpeedKmh))
                        BigStat(label: "Top speed", value: us ? String(format: "%.0f mph", t.maxSpeedKmh * 0.621371) : String(format: "%.0f km/h", t.maxSpeedKmh))
                        BigStat(label: "Driving / idling", value: "\(Self.duration(t.movingSeconds)) / \(Self.duration(t.idleSeconds))")
                    }
                    Text("Fuel is \(t.fuelSource). Air-flow estimates assume gasoline at the ideal mixture, so treat economy as approximate. OBD speed tops out at 255 km/h (158 mph).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m \(sec)s"
    }
}

struct BigStat: View {
    let label: String
    let value: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
    }
}

// MARK: - Performance

struct PerformanceView: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "Performance", subtitle: "\(s.units == .us ? "0–60 mph" : "0–100 km/h") and quarter-mile from the speed sensor")
                    Label("Closed course or track only. Keep your eyes on the road — the timer runs by itself.",
                          systemImage: "flag.checkered")
                        .foregroundStyle(.orange)
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(phaseText).font(.title2.weight(.semibold))
                            HStack(spacing: 30) {
                                Readout(label: "Speed", value: s.units == .us ? String(format: "%.0f mph", s.perf.speedKmh * 0.621371) : String(format: "%.0f km/h", s.perf.speedKmh))
                                Readout(label: "Time", value: String(format: "%.2f s", s.perf.elapsed))
                                Readout(label: "Distance", value: s.units == .us ? String(format: "%.0f ft", s.perf.distanceM * 3.28084) : String(format: "%.0f m", s.perf.distanceM))
                                Readout(label: "Samples/s", value: String(format: "%.1f", s.perf.samplesPerSecond))
                            }
                            HStack {
                                if s.perfActive {
                                    Button("Cancel") { s.cancelPerformance() }
                                } else {
                                    Button("Arm timer") { s.armPerformance() }.buttonStyle(.borderedProminent)
                                        .disabled(!s.supportedPIDs.contains(0x0D))
                                }
                            }
                        }
                    }
                    if !s.perfRuns.isEmpty {
                        Text("Runs this session").font(.headline)
                        ForEach(s.perfRuns) { run in
                            Card {
                                HStack(spacing: 30) {
                                    Readout(label: run.targetLabel, value: run.zeroToTarget.map { String(format: "%.2f s", $0) } ?? "—")
                                    Readout(label: "¼ mile", value: run.quarterMile.map { String(format: "%.2f s", $0) } ?? "—")
                                    Readout(label: "Trap speed", value: run.trapSpeedKmh.map { s.units == .us ? String(format: "%.0f mph", $0 * 0.621371) : String(format: "%.0f km/h", $0) } ?? "—")
                                    Spacer()
                                    Text(run.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Accuracy depends on how often the car reports speed (shown as samples/s). Above about 10 per second, times are typically within ±0.1 s.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
    }

    private var phaseText: String {
        switch s.perf.phase {
        case .off: return "Timer off"
        case .waitingForStop: return "Come to a complete stop…"
        case .ready: return "Ready — timer starts when the car moves"
        case .running: return "Running…"
        case .finished: return "Finished"
        }
    }
}

struct Readout: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
        }
    }
}

// MARK: - Alerts

struct AlertsView: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Alerts", subtitle: "A sound and notification when a reading crosses a limit during live data")
                if let p = s.profile {
                    ForEach(p.alerts) { rule in
                        AlertRuleRow(rule: rule, units: s.units) { updated in
                            var q = p
                            if let i = q.alerts.firstIndex(where: { $0.id == updated.id }) { q.alerts[i] = updated }
                            s.saveProfile(q)
                        } onDelete: {
                            var q = p
                            q.alerts.removeAll { $0.id == rule.id }
                            s.saveProfile(q)
                        }
                    }
                    Menu("Add alert") {
                        ForEach(PIDs.all.filter(\.onDashboard)) { def in
                            Button(def.name) {
                                var q = p
                                q.alerts.append(AlertRule(pid: def.pid, below: nil, above: nil))
                                s.saveProfile(q)
                            }
                        }
                    }
                    .frame(width: 160)
                    Text("Notifications appear when the app is built as an .app (make_app.sh); with `swift run` you'll hear the sound and see the banner.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Connect to a car first — alerts are saved per car.").foregroundStyle(.secondary)
                }

                if !s.alertLog.isEmpty {
                    Text("Recent alerts").font(.headline).padding(.top, 8)
                    ForEach(Array(s.alertLog.prefix(30).enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.0.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(item.1)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct AlertRuleRow: View {
    let rule: AlertRule
    let units: UnitSystem
    let onUpdate: (AlertRule) -> Void
    let onDelete: () -> Void

    var body: some View {
        if let def = PIDs.def(rule.pid) {
            Card {
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; onUpdate(r) }))
                        .labelsHidden()
                    Text(def.name).frame(width: 220, alignment: .leading)
                    Text("below")
                    LimitField(value: rule.below, def: def, units: units) { var r = rule; r.below = $0; onUpdate(r) }
                    Text("above")
                    LimitField(value: rule.above, def: def, units: units) { var r = rule; r.above = $0; onUpdate(r) }
                    Text(def.unitLabel(units)).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
        }
    }
}

/// Number field shown in the user's units, stored in metric. Empty = no limit.
struct LimitField: View {
    let value: Double?
    let def: PIDDef
    let units: UnitSystem
    let onCommit: (Double?) -> Void
    @State private var text = ""

    var body: some View {
        TextField("—", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            .onAppear { text = display }
            .onChange(of: units) { _, _ in text = display }
            .onSubmit {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                onCommit(Double(trimmed).map { def.toMetric($0, units) })
            }
    }

    private var display: String {
        guard let v = value else { return "" }
        return String(format: "%.1f", def.present(v, units).0)
    }
}

/// Banner shown over every page when an alert trips.
struct AlertBanner: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        if let text = s.alertBanner {
            HStack(alignment: .top) {
                Image(systemName: "bell.badge.fill").foregroundStyle(.white)
                Text(text).foregroundStyle(.white).font(.callout.weight(.medium))
                Spacer()
                Button { s.dismissAlert() } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                    .buttonStyle(.borderless)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.9)))
            .padding(12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.profile?.nickname ?? "OBD Reader").font(.headline)
            if s.isConnected {
                ForEach(s.livePIDsForMenu, id: \.self) { pid in
                    if let def = PIDs.def(pid) {
                        HStack {
                            Text(def.name).foregroundStyle(.secondary)
                            Spacer()
                            Text(s.liveValues[pid].map { def.format($0, s.units) } ?? "—").monospacedDigit()
                        }
                    }
                }
                if !s.dtcs.isEmpty {
                    Label("\(s.dtcs.count) trouble code\(s.dtcs.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button(s.isLive ? "Pause live data" : "Start live data") {
                    if s.isLive { s.stopLive() } else { s.startLive() }
                }
            } else {
                Text("Not connected").foregroundStyle(.secondary)
            }
            Divider()
            Button("Open OBD Reader") { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .padding(12)
        .frame(width: 260)
    }
}

extension VehicleSession {
    var livePIDsForMenu: [UInt8] {
        let base: [UInt8] = (profile?.menuBarPIDs ?? []) + [0x0C, 0x0D, 0x05, 0x42]
        var out: [UInt8] = []
        for p in base where !out.contains(p) && supportedPIDs.contains(p) { out.append(p) }
        return Array(out.prefix(5))
    }
}

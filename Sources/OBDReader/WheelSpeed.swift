import SwiftUI

// Wheel Speed Test: read all four ABS wheel-speed sensors while driving and compare them.
// A healthy set reads within a few percent of each other (more in tight turns). A bad sensor,
// damaged wiring or a dirty/cracked tone ring shows as one wheel dropping to zero, reading
// erratically, or reading consistently off. Read-only.
//
// Sources: older VW-group cars — ABS module 03 measuring block (usually group 001 holds the four
// wheel speeds); newer cars — Custom Readings whose names mention wheel speed (e.g. OBDb imports).

final class WheelAnalyzer: ObservableObject {
    struct Wheel: Identifiable {
        let id: Int
        var name: String
        var current: Double = 0
        var samples = 0          // samples taken while the car was moving
        var dropouts = 0         // read ~0 while the others were moving
        var offSamples = 0       // more than 5 % away from the others above 20 km/h
        var maxDeviation = 0.0   // largest % difference seen (excluding dropouts)
    }

    @Published private(set) var wheels: [Wheel] = []
    @Published private(set) var movingSamples = 0

    func reset() { wheels = []; movingSamples = 0 }

    func ingest(names: [String], values: [Double]) {
        guard values.count >= 2 else { return }
        if wheels.count != values.count || zip(wheels, names).contains(where: { $0.name != $1 }) {
            wheels = values.indices.map { Wheel(id: $0, name: $0 < names.count ? names[$0] : "Wheel \($0 + 1)") }
            movingSamples = 0
        }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        for i in values.indices { wheels[i].current = values[i] }
        guard median >= 10 else { return }               // only judge while actually moving
        movingSamples += 1
        for i in values.indices {
            let v = values[i]
            wheels[i].samples += 1
            if v < 2 {
                wheels[i].dropouts += 1
                continue
            }
            let dev = (v - median) / median * 100
            wheels[i].maxDeviation = max(wheels[i].maxDeviation, abs(dev))
            if median >= 20 && abs(dev) > 5 { wheels[i].offSamples += 1 }
        }
    }

    enum Health { case waiting, ok, suspect, bad }

    func health(_ w: Wheel) -> (Health, String) {
        guard w.samples >= 20 else { return (.waiting, "Collecting — keep driving") }
        let dropRate = Double(w.dropouts) / Double(w.samples)
        let offRate = Double(w.offSamples) / Double(w.samples)
        if dropRate > 0.5 { return (.bad, "Reads zero while the car moves — dead sensor, broken wire or unplugged connector") }
        if w.dropouts >= 3 { return (.bad, "Drops out to zero (\(w.dropouts)×) — intermittent sensor, chafed wire, loose connector or damaged tone ring") }
        if offRate > 0.3 { return (.suspect, "Often reads more than 5 % off the others — dirty/damaged tone ring, wrong tyre size or worn bearing") }
        if w.dropouts > 0 { return (.suspect, "Dropped out once or twice — keep watching") }
        return (.ok, "Tracks the other wheels")
    }

    var verdict: String {
        guard movingSamples >= 20 else {
            return "Drive at a steady speed above 15 mph (25 km/h) for a minute, mostly in a straight line. Readings while stopped aren't judged."
        }
        let bad = wheels.filter { health($0).0 == .bad }.map(\.name)
        let sus = wheels.filter { health($0).0 == .suspect }.map(\.name)
        if !bad.isEmpty { return "Likely fault: \(bad.joined(separator: ", ")). Check that wheel's sensor, its connector and wiring, and the tone ring." }
        if !sus.isEmpty { return "Watch: \(sus.joined(separator: ", ")). Keep driving to confirm; check the tone ring and connector at that wheel." }
        return "All wheel speed sensors agree. If the ABS light is on, the fault may be intermittent, in the ABS module, or low voltage — read the ABS fault codes too."
    }
}

struct WheelSpeedView: View {
    @EnvironmentObject var s: VehicleSession
    @StateObject private var an = WheelAnalyzer()
    @AppStorage("wheelSource") private var sourceRaw = Source.vwABS.rawValue
    @AppStorage("wheelGroup") private var group = 1

    enum Source: String, CaseIterable, Identifiable {
        case vwABS = "VW-group ABS module (2004–2014, TP2.0)"
        case custom = "Custom Readings (OBDb or your own)"
        var id: String { rawValue }
    }
    private var source: Source { Source(rawValue: sourceRaw) ?? .vwABS }
    private static let vwNames = ["Front left", "Front right", "Rear left", "Rear right"]

    /// Custom readings that look like wheel speeds.
    private var customWheels: [CustomPID] {
        s.customPIDs.filter { p in
            let n = p.name.lowercased()
            return p.enabled && n.contains("wheel") && n.contains("speed")
        }
        .sorted { $0.name < $1.name }
        .prefix(4).map { $0 }
    }

    private var running: Bool { source == .vwABS ? s.blocksLive : s.customLive }

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "Wheel Speed Test",
                               subtitle: "Compare all four ABS wheel-speed sensors while driving to find a bad one — read-only")
                    Label("Have a passenger watch the screen, or review the log afterwards. Never look at the laptop while driving.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Picker("Source", selection: $sourceRaw) {
                                    ForEach(Source.allCases) { Text($0.rawValue).tag($0.rawValue) }
                                }
                                .frame(width: 380)
                                if source == .vwABS {
                                    Stepper("Group \(String(format: "%03d", group))", value: $group, in: 0...255).frame(width: 150)
                                }
                                Spacer()
                                if running {
                                    Button("Stop", role: .destructive) { stop() }
                                } else {
                                    Button("Start") { start() }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(s.busy != nil || (source == .custom && customWheels.isEmpty)
                                                  || (source == .vwABS && (!s.isCAN || s.protocolName.contains("29-bit"))))
                                }
                                Button("Reset") { an.reset() }
                            }
                            Text(source == .vwABS
                                 ? "Reads the ABS module (address 03). On most VW-group ABS units group 001 shows the four wheel speeds, usually in the order front-left, front-right, rear-left, rear-right. If the numbers don't look like speeds, try other groups. To confirm which wheel is which, lift one wheel and spin it by hand with the ignition on."
                                 : (customWheels.isEmpty
                                    ? "No enabled Custom Readings with \"wheel speed\" in the name. On Custom Readings, use Get from OBDb (or add your own), search \"wheel speed\" and enable them."
                                    : "Using: " + customWheels.map(\.name).joined(separator: " · ")))
                                .font(.caption).foregroundStyle(.secondary)
                            if let st = s.blockStatus, source == .vwABS { Text(st).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    if !an.wheels.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                            ForEach(an.wheels) { w in WheelTile(wheel: w, health: an.health(w), units: s.units) }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Result").font(.headline)
                            Text(an.verdict)
                            Text("\(an.movingSamples) moving samples. Small differences (1–3 %) are normal in turns; wheelspin and hard braking also cause short spikes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if source == .vwABS && s.blockLogCount > 0 {
                        HStack {
                            Spacer()
                            Button("Save log as CSV…") { s.exportBlockCSV() }
                        }
                    }
                }
                .padding(24)
            }
            .onChange(of: s.blockRound) { _, _ in
                guard source == .vwABS, let g = s.blockReadings.first, g.error == nil else { return }
                var fields = g.fields.filter { $0.unit == "km/h" && $0.value != nil }
                if fields.count < 2 { fields = g.fields.filter { $0.value != nil } }
                let values = fields.prefix(4).compactMap(\.value)
                an.ingest(names: Array(Self.vwNames.prefix(values.count)), values: values)
            }
            .onChange(of: s.customValues) { _, vals in
                guard source == .custom, s.customLive else { return }
                let list = customWheels
                let values = list.compactMap { p -> Double? in
                    guard let v = vals[p.id] else { return nil }
                    return toKmh(v, unit: p.unit)
                }
                guard values.count == list.count else { return }
                an.ingest(names: list.map(\.name), values: values)
            }
        }
    }

    private func toKmh(_ v: Double, unit: String) -> Double {
        unit == "mph" ? v / 0.621371 : v
    }

    private func start() {
        an.reset()
        if source == .vwABS {
            Task { await s.readBlocks(address: 0x03, groups: [UInt8(group)], live: true) }
        } else if !s.customLive {
            s.toggleCustomLive()
        }
    }

    private func stop() {
        if source == .vwABS { s.stopBlocks() } else if s.customLive { s.toggleCustomLive() }
    }
}

private struct WheelTile: View {
    let wheel: WheelAnalyzer.Wheel
    let health: (WheelAnalyzer.Health, String)
    let units: UnitSystem

    private var color: Color {
        switch health.0 {
        case .waiting: return .secondary
        case .ok: return .green
        case .suspect: return .orange
        case .bad: return .red
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(wheel.name).font(.headline)
                }
                Text(units == .us ? String(format: "%.1f mph", wheel.current * 0.621371) : String(format: "%.1f km/h", wheel.current))
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                Text("Dropouts \(wheel.dropouts) · max diff \(String(format: "%.1f", wheel.maxDeviation)) %")
                    .font(.caption).foregroundStyle(.secondary)
                Text(health.1).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

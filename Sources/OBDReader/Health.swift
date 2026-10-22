import Foundation
import SwiftUI
import Charts
import AppKit

// MARK: - Engine health, worked out from live data
//
// These are indicators built from standard readings, not pass/fail tests. They point at where to
// look; the car's own self-tests (Self-Tests page) and codes remain the authority.

struct EngineHealth {
    // Fuel trim map: average total trim (short + long term) by RPM band × load band, per bank,
    // collected only while the engine is in closed loop.
    static let rpmBands = ["Idle", "1–2k", "2–3k", "3–4k", "4k+"]
    static let loadBands = ["0–25%", "25–50%", "50–75%", "75–100%"]
    private(set) var trimSum: [[[Double]]] = Array(repeating: Array(repeating: [0, 0], count: 4), count: 5)
    private(set) var trimCount: [[[Int]]] = Array(repeating: Array(repeating: [0, 0], count: 4), count: 5)

    // Oxygen-sensor switching (narrowband sensors, 0.45 V threshold)
    private(set) var switches: [UInt8: Int] = [:]
    private var lastSide: [UInt8: Bool] = [:]
    private(set) var o2Seconds = 0.0

    // Warm-up curve: (minutes since start, coolant °C)
    private(set) var warmup: [(minutes: Double, coolant: Double)] = []
    private(set) var reached80At: Double?

    // Idle smoothness: RPM spread while stopped and off the throttle
    private var idleRPM: [Double] = []
    private(set) var idleWobble: Double?

    private var lastFeed: Date?

    static func rpmBand(_ rpm: Double) -> Int {
        switch rpm { case ..<1000: return 0; case ..<2000: return 1; case ..<3000: return 2; case ..<4000: return 3; default: return 4 }
    }
    static func loadBand(_ load: Double) -> Int { min(3, max(0, Int(load / 25))) }

    mutating func reset() { self = EngineHealth() }

    mutating func feed(_ v: [UInt8: Double], at now: Date) {
        let dt = lastFeed.map { now.timeIntervalSince($0) } ?? 0
        lastFeed = now
        let rpm = v[0x0C] ?? 0
        let running = rpm > 300
        let closed = PIDs.closedLoop(v[0x03]) != false

        // Trims
        if running, closed, let load = v[0x04] {
            let r = Self.rpmBand(rpm), l = Self.loadBand(load)
            if let st = v[0x06], let lt = v[0x07] { trimSum[r][l][0] += st + lt; trimCount[r][l][0] += 1 }
            if let st = v[0x08], let lt = v[0x09] { trimSum[r][l][1] += st + lt; trimCount[r][l][1] += 1 }
        }

        // O2 switching (only while running in closed loop, gaps ignored)
        if running, closed, dt > 0, dt < 3 {
            var counted = false
            for pid: UInt8 in [0x14, 0x15, 0x18, 0x19] {
                guard let volts = v[pid] else { continue }
                let rich = volts > 0.45
                if let prev = lastSide[pid], prev != rich { switches[pid, default: 0] += 1 }
                lastSide[pid] = rich
                counted = true
            }
            if counted { o2Seconds += dt }
        }

        // Warm-up
        if let runtime = v[0x1F], let ect = v[0x05], running {
            let minutes = runtime / 60
            if warmup.last.map({ minutes - $0.minutes >= 0.25 || minutes < $0.minutes }) ?? true {
                if let last = warmup.last, minutes < last.minutes { warmup = [] ; reached80At = nil }   // new engine start
                warmup.append((minutes, ect))
                if warmup.count > 400 { warmup.removeFirst(warmup.count - 400) }
            }
            if reached80At == nil, ect >= 80 { reached80At = minutes }
        }

        // Idle
        if running, (v[0x0D] ?? 0) < 1, rpm < 1300, (v[0x11] ?? 0) < 20 {
            idleRPM.append(rpm)
            if idleRPM.count > 60 { idleRPM.removeFirst(idleRPM.count - 60) }
            if idleRPM.count >= 20 {
                let mean = idleRPM.reduce(0, +) / Double(idleRPM.count)
                let varSum = idleRPM.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                idleWobble = (varSum / Double(idleRPM.count)).squareRoot()
            }
        }
    }

    func trim(_ r: Int, _ l: Int, bank: Int) -> Double? {
        let n = trimCount[r][l][bank]
        return n >= 3 ? trimSum[r][l][bank] / Double(n) : nil
    }
    var hasBank2: Bool { trimCount.joined().contains { $0[1] > 0 } }
    var trimSamples: Int { trimCount.joined().reduce(0) { $0 + $1[0] + $1[1] } }

    /// Plain-English reading of the trim map (bank index 0 or 1).
    func trimPattern(bank: Int) -> String? {
        let idle = (0..<4).compactMap { trim(0, $0, bank: bank) }
        let higher = (1..<5).flatMap { r in (0..<4).compactMap { trim(r, $0, bank: bank) } }
        guard !idle.isEmpty, !higher.isEmpty else { return nil }
        let i = idle.reduce(0, +) / Double(idle.count), h = higher.reduce(0, +) / Double(higher.count)
        if i > 10 && h < 5 { return "Lean mainly at idle, close to normal higher up — the classic pattern of an air (vacuum) leak." }
        if i > 10 && h > 10 { return "Lean at idle and higher up — points to fuel delivery (pressure, pump, injectors) or an air-flow sensor reading low." }
        if i < -10 && h < -10 { return "Rich across the range — check for leaking injectors, high fuel pressure or a contaminated air-flow sensor." }
        if abs(i) <= 10 && abs(h) <= 10 { return "Trims within ±10 % everywhere — fuel control looks healthy." }
        return nil
    }

    /// Rear-to-front switching ratio for one bank. Front: 0x14 (B1) / 0x18 (B2); rear: 0x15 / 0x19.
    func catalystRatio(bank: Int) -> (front: Int, rear: Int, ratio: Double)? {
        let f = switches[bank == 0 ? 0x14 : 0x18] ?? 0, r = switches[bank == 0 ? 0x15 : 0x19] ?? 0
        guard f >= 20 else { return nil }
        return (f, r, Double(r) / Double(f))
    }
}

// MARK: - Page

struct HealthView: View {
    @EnvironmentObject var s: VehicleSession
    @EnvironmentObject var garage: GarageStore
    static let focusPIDs: [UInt8] = [0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0C, 0x0D, 0x11,
                                     0x14, 0x15, 0x18, 0x19, 0x1F]

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        PageHeader(title: "Engine Health",
                                   subtitle: "Patterns worked out from live data — indicators to guide checks, not verdicts")
                        Spacer()
                        Button(s.isLive ? "Stop" : "Start live data") { if s.isLive { s.stopLive() } else { s.startLive() } }
                        Button("Reset") { s.resetHealth() }
                    }
                    if !s.isLive {
                        Text("Start live data and drive normally — idle, town and some steady cruising. The maps fill in as you go.")
                            .foregroundStyle(.secondary)
                    }
                    trimMap
                    catalyst
                    warmup
                    idle
                    trends
                }
                .padding(24)
            }
            .onAppear { s.setFocus("health", Self.focusPIDs) }
            .onDisappear { s.setFocus("health", nil) }
        }
    }

    // Fuel trim map
    @ViewBuilder private var trimMap: some View {
        let h = s.health
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fuel trim map").font(.headline)
                Text("Average correction (short + long term) the engine computer applies, by engine speed and load, in closed loop only. Positive = adding fuel (lean), negative = removing fuel (rich).")
                    .font(.caption).foregroundStyle(.secondary)
                if h.trimSamples == 0 {
                    Text("No closed-loop samples yet.").foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        trimGrid(bank: 0)
                        if h.hasBank2 { trimGrid(bank: 1) }
                    }
                    ForEach(h.hasBank2 ? [0, 1] : [0], id: \.self) { b in
                        if let p = h.trimPattern(bank: b) { Text("Bank \(b + 1): \(p)").font(.callout) }
                    }
                }
            }
        }
    }

    private func trimGrid(bank: Int) -> some View {
        let h = s.health
        return VStack(alignment: .leading, spacing: 4) {
            Text("Bank \(bank + 1)").font(.caption.bold())
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    Text("load ↓ / rpm →").font(.caption2).foregroundStyle(.secondary)
                    ForEach(0..<5, id: \.self) { r in Text(EngineHealth.rpmBands[r]).font(.caption2).foregroundStyle(.secondary) }
                }
                ForEach([3, 2, 1, 0], id: \.self) { l in
                    GridRow {
                        Text(EngineHealth.loadBands[l]).font(.caption2).foregroundStyle(.secondary)
                        ForEach(0..<5, id: \.self) { r in
                            let v = h.trim(r, l, bank: bank)
                            Text(v.map { String(format: "%+.0f", $0) } ?? "·")
                                .font(.caption.monospacedDigit())
                                .frame(width: 44, height: 24)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Self.trimColor(v)))
                        }
                    }
                }
            }
        }
    }

    static func trimColor(_ v: Double?) -> Color {
        guard let v else { return Color.primary.opacity(0.05) }
        let a = min(abs(v) / 25, 1) * 0.6 + 0.1
        if abs(v) <= 5 { return Color.green.opacity(0.25) }
        return (v > 0 ? Color.orange : Color.blue).opacity(a)
    }

    // Catalyst indicator
    @ViewBuilder private var catalyst: some View {
        let h = s.health
        let banks = (0..<2).compactMap { b in h.catalystRatio(bank: b).map { (b, $0) } }
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Catalyst indicator").font(.headline)
                Text("Behind a working catalyst the rear oxygen sensor stays fairly steady while the front one switches rich/lean constantly. The more the rear copies the front, the less oxygen the catalyst is storing. Needs narrowband sensors (cars with a wideband front sensor won't show this).")
                    .font(.caption).foregroundStyle(.secondary)
                if banks.isEmpty {
                    Text(h.o2Seconds > 0 ? "Collecting — needs at least 20 front-sensor switches in closed loop." : "No oxygen-sensor voltages from this car yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(banks, id: \.0) { item in
                    let b = item.0
                    let c = item.1
                    HStack {
                        Text("Bank \(b + 1)").bold()
                        Text("front switched \(c.front)×, rear \(c.rear)× — ratio \(String(format: "%.2f", c.ratio))")
                            .monospacedDigit()
                        Spacer()
                        Text(c.ratio < 0.3 ? "Rear steady" : c.ratio < 0.7 ? "Watch" : "Rear copying front")
                            .font(.caption.bold())
                            .foregroundStyle(c.ratio < 0.3 ? Color.green : c.ratio < 0.7 ? Color.orange : Color.red)
                    }
                }
                Text("A rough guide only — the car's own catalyst self-test on the Self-Tests page is the real measure.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // Warm-up
    @ViewBuilder private var warmup: some View {
        let h = s.health
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Warm-up").font(.headline)
                if h.warmup.count < 2 {
                    Text("Start from a cold engine with live data running to see the warm-up curve.").foregroundStyle(.secondary)
                } else {
                    Chart(h.warmup.indices, id: \.self) { i in
                        let p = h.warmup[i]
                        LineMark(x: .value("Minutes", p.minutes),
                                 y: .value("Coolant", UnitKind.temperature.present(p.coolant, s.units).0))
                    }
                    .chartYAxisLabel(UnitKind.temperature.present(0, s.units).1)
                    .frame(height: 140)
                    if let m = h.reached80At {
                        Text(String(format: "Reached %@ after %.1f minutes of running.", UnitKind.temperature.format(80, s.units), m))
                    } else if let last = h.warmup.last, last.minutes > 15 {
                        Text("Still below \(UnitKind.temperature.format(80, s.units)) after \(Int(last.minutes)) minutes — a thermostat stuck open or a coolant sensor reading low are the usual causes.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // Idle
    @ViewBuilder private var idle: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Idle smoothness").font(.headline)
                if let w = s.health.idleWobble {
                    Text(String(format: "RPM varies by ±%.0f at idle (lower is smoother).", w)).font(.title3.monospacedDigit())
                    Text("Saved with each scan, so the History trend below shows whether it's getting rougher. A rising number alongside misfire counts points to ignition or an air leak.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Let the car idle in park/neutral for about a minute with live data running.").foregroundStyle(.secondary)
                }
            }
        }
    }

    // Trends across saved scans
    @ViewBuilder private var trends: some View {
        let records = s.profile.map { garage.history($0.vin) } ?? []
        let misfires = records.compactMap { r in r.misfireTotal.map { (r.date, Double($0)) } }
        let margins = records.compactMap { r in r.worstMargin.map { (r.date, $0 * 100) } }
        let wobble = records.compactMap { r in r.idleWobble.map { (r.date, $0) } }
        let volts = records.compactMap { r in r.battery.map { (r.date, $0) } }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Trends across scans").font(.headline)
                if records.count < 2 {
                    Text("Builds up as you scan this car on different days.").foregroundStyle(.secondary)
                }
                trendChart("Misfires last drive (all cylinders)", misfires, unit: "")
                trendChart("Closest self-test to its limit (% of range left)", margins, unit: "%")
                trendChart("Idle RPM spread", wobble, unit: "rpm")
                trendChart("Battery at scan", volts, unit: "V")
            }
        }
    }

    @ViewBuilder private func trendChart(_ title: String, _ pts: [(Date, Double)], unit: String) -> some View {
        if pts.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold())
                Chart(pts.indices, id: \.self) { i in
                    LineMark(x: .value("Date", pts[i].0), y: .value(title, pts[i].1))
                    PointMark(x: .value("Date", pts[i].0), y: .value(title, pts[i].1))
                }
                .chartYAxisLabel(unit)
                .frame(height: 110)
            }
        }
    }
}

// MARK: - Recalls and official records

struct Recall: Identifiable {
    let campaign: String
    let component: String
    let summary: String
    let consequence: String
    let remedy: String
    let date: String
    var id: String { campaign }
}

enum RecallService {
    /// NHTSA recalls API (US) — by make, model and model year; it does not take a VIN.
    static func fetch(make: String, model: String, year: Int) async throws -> [Recall] {
        var c = URLComponents(string: "https://api.nhtsa.gov/recalls/recallsByVehicle")!
        c.queryItems = [URLQueryItem(name: "make", value: make), URLQueryItem(name: "model", value: model),
                        URLQueryItem(name: "modelYear", value: String(year))]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.map { r in
            func s(_ k: String) -> String { (r[k] as? String) ?? "" }
            return Recall(campaign: s("NHTSACampaignNumber"), component: s("Component"), summary: s("Summary"),
                          consequence: s("Consequence"), remedy: s("Remedy"), date: s("ReportReceivedDate"))
        }
    }

    static let ukMOTHistory = URL(string: "https://www.check-mot.service.gov.uk/")!
    static let ukRecallCheck = URL(string: "https://www.gov.uk/check-vehicle-recall")!
}

struct RecallsSection: View {
    @EnvironmentObject var s: VehicleSession
    @State private var recalls: [Recall]?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recalls & official records").font(.headline)
                let p = s.profile
                let make = p?.make ?? VINDecoder.manufacturer(p?.vin ?? "") ?? ""
                let model = p?.model ?? ""
                let year = p?.modelYear
                let region = p?.region ?? ""
                if region != CarProfile.regionUK {
                    HStack {
                        Text("US recalls (NHTSA)").bold()
                        Spacer()
                        Button(loading ? "Checking…" : "Check recalls") {
                            Task {
                                loading = true; error = nil
                                defer { loading = false }
                                do { recalls = try await RecallService.fetch(make: make, model: model, year: year ?? 0) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        .disabled(loading || make.isEmpty || model.isEmpty || year == nil)
                    }
                    if make.isEmpty || model.isEmpty || year == nil {
                        Text("Set the make, model and model year in the Garage first — NHTSA looks recalls up by those, not by VIN.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                    if let recalls {
                        if recalls.isEmpty {
                            Text("NHTSA lists no recalls for \(year.map(String.init) ?? "") \(make) \(model).").foregroundStyle(.green)
                        }
                        ForEach(recalls) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(r.campaign) · \(r.component)").font(.callout.bold())
                                Text(r.summary).font(.callout)
                                if !r.remedy.isEmpty { Text("Remedy: \(r.remedy)").font(.caption).foregroundStyle(.secondary) }
                            }
                            .padding(.vertical, 4)
                        }
                        Text("Whether a recall has already been done on this particular car is shown by the dealer or the maker's own VIN lookup.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if region.isEmpty || region == CarProfile.regionUK {
                    HStack {
                        Text("UK").bold()
                        Spacer()
                        Button("MOT history (mileage at each test)…") { NSWorkspace.shared.open(RecallService.ukMOTHistory) }
                        Button("UK recall check…") { NSWorkspace.shared.open(RecallService.ukRecallCheck) }
                    }
                    Text("Both need the number plate. Compare the MOT mileages with the odometer on the Pre-Purchase page.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    MOTHistorySection()
                }
            }
        }
    }
}

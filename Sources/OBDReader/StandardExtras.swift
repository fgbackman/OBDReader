import Foundation
import SwiftUI

// MARK: - In-use performance tracking (Service 09, InfoType 08 — spark-ignition cars)
//
// Pairs of counters per emissions monitor: how many times it completed vs how many times the
// driving conditions for it were met. A low ratio means a monitor rarely gets to run.
// Counter order follows SAE J1979 for spark-ignition vehicles; verify on the first real car.

struct InUsePerformance {
    struct Monitor: Identifiable {
        let name: String
        let completions: Int
        let conditions: Int
        var id: String { name }
        var ratio: Double? { conditions > 0 ? Double(completions) / Double(conditions) : nil }
    }

    let obdConditions: Int      // times the car was driven in OBD monitoring conditions
    let ignitionCycles: Int     // engine starts
    let monitors: [Monitor]

    private static let names = ["Catalyst bank 1", "Catalyst bank 2", "O2 sensor bank 1", "O2 sensor bank 2",
                                "EGR / VVT", "Secondary air", "Evaporative system",
                                "Rear O2 sensor bank 1", "Rear O2 sensor bank 2"]

    init?(payload: [UInt8]) {
        let words = stride(from: 0, to: payload.count - 1, by: 2).map { Int(payload[$0]) << 8 | Int(payload[$0 + 1]) }
        guard words.count >= 2 else { return nil }
        obdConditions = words[0]
        ignitionCycles = words[1]
        var list: [Monitor] = []
        var i = 2
        for name in Self.names where i + 1 < words.count {
            list.append(Monitor(name: name, completions: words[i], conditions: words[i + 1]))
            i += 2
        }
        monitors = list
    }
}

// MARK: - Self-test results on older (pre-CAN) cars
//
// Before CAN, Service 06 replied per Test ID with: [46, TID, CID, value(2), limit(2)].
// Bit 7 of the component ID says whether the limit is a minimum (1) or maximum (0).
// Units and meanings are manufacturer-defined, so values are shown raw.

struct LegacyTestResult: Identifiable {
    let ecu: String
    let tid: UInt8
    let cid: UInt8
    let value: Int
    let limit: Int

    var isMinLimit: Bool { cid & 0x80 != 0 }
    var component: Int { Int(cid & 0x7F) }
    var passed: Bool { isMinLimit ? value >= limit : value <= limit }
    var id: String { "\(ecu)-\(tid)-\(cid)" }
}

enum LegacyMode06 {
    static func parse(_ msg: ECUMessage) -> [LegacyTestResult] {
        msg.frames.compactMap { f in
            guard f.count >= 7, f[0] == 0x46, f[1] != 0x00 else { return nil }
            return LegacyTestResult(ecu: msg.ecu, tid: f[1], cid: f[2],
                                    value: Int(f[3]) << 8 | Int(f[4]),
                                    limit: Int(f[5]) << 8 | Int(f[6]))
        }
    }
}

// MARK: - Views used on the Readiness and Self-Tests pages

struct DriveCycleSection: View {
    let readiness: Readiness
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This drive cycle").font(.headline).padding(.top, 8)
            Text("Which emissions tests have finished since the engine was started (standard PID 41).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(readiness.monitors) { m in
                HStack {
                    Image(systemName: m.complete ? "checkmark.circle.fill" : "clock.fill")
                        .foregroundStyle(m.complete ? .green : .orange)
                    Text(m.name)
                    Spacer()
                    Text(m.complete ? "Done this drive" : "Not yet").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

struct InUsePerformanceSection: View {
    let ipt: InUsePerformance
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How often each test gets to run").font(.headline).padding(.top, 8)
            Text("In-use performance counters (Service 09): \(ipt.ignitionCycles) engine starts, \(ipt.obdConditions) qualifying drives. A monitor with few completions compared with its opportunities rarely finishes.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                GridRow {
                    Text("Monitor").font(.caption.bold())
                    Text("Completed").font(.caption.bold())
                    Text("Opportunities").font(.caption.bold())
                    Text("Ratio").font(.caption.bold())
                }
                ForEach(ipt.monitors) { m in
                    GridRow {
                        Text(m.name)
                        Text("\(m.completions)").monospacedDigit()
                        Text("\(m.conditions)").monospacedDigit()
                        Text(m.ratio.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit()
                    }
                }
            }
        }
    }
}

struct LegacyTestsSection: View {
    let tests: [LegacyTestResult]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Self-test results (older car format)").font(.headline)
            Text("Before CAN, test meanings and units were set by each carmaker, so values are shown as reported. Your service information can tell you what each test ID checks.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(tests) { t in
                Card {
                    HStack {
                        Image(systemName: t.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(t.passed ? .green : .red)
                        Text(String(format: "Test %02X · component %d", Int(t.tid), t.component))
                        Text("ECU \(t.ecu)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(t.value)").monospacedDigit()
                        Text(t.isMinLimit ? "min \(t.limit)" : "max \(t.limit)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}


// MARK: - Drive-cycle coach

/// How to drive so incomplete readiness monitors finish. General guidance that works on most cars;
/// each maker's exact drive cycle is in its service information.
enum DriveCycleCoach {
    static let tips: [String: String] = [
        "Catalyst": "Warm the engine fully, then hold a steady 45–60 mph (70–100 km/h) cruise for 5–10 minutes with light throttle.",
        "Heated catalyst": "Same as the catalyst: steady cruise after the engine is fully warm.",
        "Evaporative system": "Usually needs the car to sit 8+ hours first (overnight), fuel between about ¼ and ¾ of a tank, and mild weather. Many cars run it during the first drive of the day or after you switch off. Make sure the fuel cap clicks shut.",
        "Secondary air": "Runs right after a cold start: start the cold engine and let it idle for 2–3 minutes before driving.",
        "Oxygen sensor": "After warm-up, cruise steadily at 30–55 mph for a few minutes, then make a few gentle slow-downs with your foot off the pedal.",
        "Oxygen sensor heater": "Usually finishes within minutes of a cold start. If it never finishes after a few drives, the heater circuit may be faulty.",
        "EGR/VVT": "With the engine warm, make several long, gentle slow-downs from 40–55 mph with your foot off the pedal and no braking.",
        "A/C refrigerant": "Rarely used; run the A/C for a few minutes during a warm drive.",
        "NMHC catalyst": "Diesel: a long steady highway drive after warm-up.",
        "NOx/SCR aftertreatment": "Diesel: a long steady highway drive after warm-up, with DEF/AdBlue topped up.",
        "Boost pressure": "Diesel: several firm accelerations and steady cruising after warm-up.",
        "Exhaust gas sensor": "Diesel: steady highway cruising after warm-up.",
        "PM filter": "Diesel: 20+ minutes of steady highway driving so the particulate filter can regenerate.",
        "Misfire": "Runs continuously while driving.",
        "Fuel system": "Runs continuously while driving.",
        "Comprehensive components": "Runs continuously while driving.",
    ]

    static let pattern = [
        "Let the car sit overnight (8+ hours) with fuel between ¼ and ¾ tank.",
        "Start cold and idle 2–3 minutes (secondary air, O2 heaters).",
        "Drive gently to highway speed and hold 45–60 mph for 5–10 minutes (catalyst, O2 sensors).",
        "Lift off and coast down to about 20 mph without braking; repeat 2–3 times (EGR/VVT, O2 sensors).",
        "Finish with 5 minutes of normal town driving, then park and switch off.",
        "Repeat over 2–5 days, then press Rescan to see what finished.",
    ]
}

struct DriveCycleCoachSection: View {
    let readiness: Readiness
    let thisDrive: Readiness?
    var body: some View {
        let open = readiness.monitors.filter { !$0.complete }
        if !open.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Drive-cycle coach").font(.headline)
                    Text("How to drive so the \(open.count) unfinished test\(open.count == 1 ? "" : "s") can run. This is general guidance; each carmaker's exact drive cycle is in its service information.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(open) { m in
                        let done = thisDrive?.monitors.first(where: { $0.name == m.name })?.complete == true
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: done ? "checkmark.circle.fill" : "steeringwheel")
                                .foregroundStyle(done ? Color.green : Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name + (done ? " — finished this drive" : "")).bold()
                                Text(DriveCycleCoach.tips[m.name] ?? "Mixed driving over a few days.")
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Divider()
                    Text("A drive that covers most tests").font(.subheadline.bold())
                    ForEach(Array(DriveCycleCoach.pattern.enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). \(step)").font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

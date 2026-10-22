import Foundation

/// Plain-English findings built from codes, readiness and a live-data snapshot.
/// These are leads to check, not a verdict — a technician should confirm before parts are replaced.
struct Finding: Identifiable {
    enum Severity: Int, Comparable {
        case info = 0, watch = 1, attention = 2, urgent = 3
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        var label: String { ["Info", "Watch", "Attention", "Urgent"][rawValue] }
    }
    let id = UUID()
    let severity: Severity
    let title: String
    let detail: String
    let checks: [String]
}

enum Diagnosis {
    static func analyze(dtcs: [DTC], readiness: Readiness?, live: [UInt8: Double],
                        battery: Double?, tests: [TestResult] = [], cylinders: Int? = nil,
                        moduleFaults: [(name: String, count: Int)] = []) -> [Finding] {
        var out: [Finding] = []

        // Faults in other modules (All Modules / TP2.0 scans)
        if !moduleFaults.isEmpty {
            let names = moduleFaults.map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
            let lower = moduleFaults.map { $0.name.lowercased() }
            var checks: [String] = []
            if lower.contains(where: { $0.contains("abs") || $0.contains("brake") }) {
                checks += ["Brake fluid level", "Wheel speed sensors and their wiring/connectors at each wheel",
                           "Run the Wheel Speed Test while driving to see which wheel drops out", "ABS module connector and fuse"]
            }
            if lower.contains(where: { $0.contains("airbag") }) {
                checks += ["Airbag light on means the airbags may not deploy — have it checked soon",
                           "Seat connectors under the front seats and the steering-wheel clock spring are common causes"]
            }
            checks.append("Write down the codes before any repair; read them again after fixing the cause")
            out.append(Finding(severity: .attention, title: "Faults stored in \(moduleFaults.count) other module\(moduleFaults.count == 1 ? "" : "s")",
                               detail: "\(names). These are outside the engine computer, so a basic OBD-II reader doesn't see them.",
                               checks: checks))
        }

        // Several modules complaining + low voltage: fix the battery first
        let volts = battery ?? live[0x42]
        let commCodes = dtcs.filter { $0.code.hasPrefix("U") }.count
        if let v = volts, v < 12.4, moduleFaults.count >= 2 || commCodes >= 2 {
            out.append(Finding(severity: .attention, title: String(format: "Low voltage (%.1f V) with faults in several modules", v),
                               detail: "Low battery voltage makes modules log faults all at once — ABS, airbag, stability-control and communication lights together are a classic sign. Fix the voltage first, then read the codes again before replacing parts.",
                               checks: ["Charge and load-test the battery (about 12.6 V rested)",
                                        "Clean and tighten battery terminals and the main ground straps",
                                        "Check charging voltage with the engine running (about 13.5–14.7 V)"]))
        }

        // On-board self-test results (Mode 06)
        let failed = tests.filter { !$0.passed }
        if !failed.isEmpty {
            out.append(Finding(
                severity: .attention,
                title: "\(failed.count) self-test\(failed.count == 1 ? "" : "s") failed",
                detail: failed.map { "\($0.monitorName): \($0.testName) — \($0.formatted($0.scaled.value)) (allowed \($0.formatted($0.scaled.min)) to \($0.formatted($0.scaled.max)))" }
                    .joined(separator: "; "),
                checks: ["Failed self-tests usually match a stored or pending code; they confirm which part the car itself measured as out of range"]))
        }
        let near = tests.filter(\.nearLimit)
        if !near.isEmpty {
            let nearList: String = near.map { "\($0.monitorName): \($0.testName)" }.joined(separator: "; ")
            out.append(Finding(
                severity: .watch,
                title: "\(near.count) self-test\(near.count == 1 ? "" : "s") close to the limit",
                detail: nearList + ". Still passing, but within 10 % of failing — likely to set a code soon.",
                checks: ["Re-check after a few drives in History to see if it's trending worse"]))
        }
        let misfireCyls = tests.filter { $0.cylinder != nil && $0.tid == 0x0C && $0.raw > 0 }
        if let worst = misfireCyls.max(by: { $0.raw < $1.raw }), worst.raw >= 5 {
            let perCyl: String = misfireCyls.sorted { $0.raw > $1.raw }
                .map { "cyl \($0.cylinder ?? 0): \($0.raw)" }.joined(separator: ", ")
            out.append(Finding(
                severity: .watch,
                title: "Misfire counter: cylinder \(worst.cylinder!) (\(worst.raw) last drive)",
                detail: "The engine computer counted misfires per cylinder: \(perCyl). One cylinder standing out points to that cylinder's coil, plug or injector.",
                checks: ["Swap the coil from that cylinder to another and see if the count moves with it"]))
        }
        // Cylinders 13–16: standard per-cylinder slots only reach 12, so on a 16-cylinder engine
        // whose second computer didn't report its own counters, recover the beyond-12 misfires as a
        // group by subtracting the per-cylinder counts from the engine's total (MID A1, this drive).
        let haveBeyond12 = misfireCyls.contains { ($0.cylinder ?? 0) > 12 }
        if !haveBeyond12, (cylinders ?? 16) > 12,
           let total = tests.first(where: { $0.mid == 0xA1 && $0.tid == 0x0C })?.raw {
            let counted = misfireCyls.reduce(0) { $0 + $1.raw }
            let beyond = total - counted
            if beyond >= 5 {
                out.append(Finding(
                    severity: .watch,
                    title: "Misfires on cylinders beyond 12 (\(beyond), grouped)",
                    detail: "The engine's total misfire count is \(total) this drive, but only \(counted) are on cylinders 1–12. The remaining \(beyond) are on higher-numbered cylinders that standard OBD-II can't name individually. On a W16, reading the second engine computer, or the factory tool, is needed to pin down which one.",
                    checks: ["If this is a W16, confirm both engine computers are being read on the Self-Tests page"]))
            }
        }

        let codes = Set(dtcs.map(\.code))
        let lt1 = live[0x07], lt2 = live[0x09], st1 = live[0x06], st2 = live[0x08]
        let rpm = live[0x0C] ?? 0
        let running = rpm > 300
        // Fuel trims only mean something in closed loop (engine steering by its O2 sensors).
        // In open loop — cold, full throttle, decel — they sit at fixed values, so judging them
        // would give false lean/rich findings. Unknown status → trust the trims as before.
        let closedLoop = PIDs.closedLoop(live[0x03])
        let trimsValid = closedLoop != false
        if running, let fs = live[0x03], Int(fs) == 8 {
            out.append(Finding(severity: .attention, title: "Engine in open loop because of a fault",
                               detail: "The engine computer has stopped using its oxygen sensors because it detected a problem, so it's running on a fixed fuel map. Expect worse economy and emissions until it's fixed.",
                               checks: ["Look at the O2 sensor and fuel-system codes", "Check O2 sensor heaters and wiring"]))
        } else if running, let fs = live[0x03], Int(fs) == 16 {
            out.append(Finding(severity: .watch, title: "O2 sensor feedback fault",
                               detail: "The engine is in closed loop but reports a fault in at least one oxygen sensor's feedback.",
                               checks: ["Compare upstream O2 / wideband sensor activity between banks"]))
        }

        // Misfires
        let misfires = dtcs.filter { $0.code.hasPrefix("P030") || $0.code.hasPrefix("P031") }
        if !misfires.isEmpty {
            let cyl = misfires.compactMap { Int($0.code.suffix(2)) }.filter { $0 > 0 && $0 <= 12 }
            let urgent = misfires.contains { $0.kind == .stored }
            out.append(Finding(
                severity: urgent ? .urgent : .attention,
                title: cyl.isEmpty ? "Misfire detected" : "Misfire on cylinder \(cyl.map { String($0) }.joined(separator: ", "))",
                detail: "Unburnt fuel from a misfire can overheat and damage the catalytic converters. Avoid hard driving until it's found.",
                checks: cyl.count == 1
                    ? ["Swap that cylinder's ignition coil with a neighbour and see if the misfire follows it",
                       "Inspect/replace the spark plug", "Check injector connector and resistance",
                       "Compression/leak-down test if coil and plug are fine"]
                    : ["Look for a common cause: vacuum leak, low fuel pressure, wet/failed coil pack harness",
                       "Check fuel trims on the same bank", "Check for recent fuel quality issues"]))
        }

        // Lean / rich
        let lean1 = codes.contains("P0171") || (trimsValid && (lt1 ?? 0) + (st1 ?? 0) > 15)
        let lean2 = codes.contains("P0174") || (trimsValid && (lt2 ?? 0) + (st2 ?? 0) > 15)
        if lean1 || lean2 {
            let banks = [lean1 ? "1" : nil, lean2 ? "2" : nil].compactMap { $0 }.joined(separator: " & ")
            out.append(Finding(
                severity: codes.contains("P0171") || codes.contains("P0174") ? .attention : .watch,
                title: "Running lean on bank \(banks)",
                detail: "The engine computer is adding fuel to compensate for extra (unmetered) air or too little fuel."
                    + (lean1 && lean2 ? " Both banks lean points to a shared cause (MAF, fuel pressure, intake leak)." :
                       " One bank only points to something on that side (intake gasket, injector, hose)."),
                checks: ["Smoke-test the intake for vacuum leaks (hoses, PCV, intake gaskets)",
                         "Check MAF reading vs. expected at idle and clean/inspect the sensor",
                         "Check fuel pressure under load", "Watch trims at idle vs. 2,500 rpm: lean only at idle → vacuum leak; lean everywhere → fuel delivery/MAF"]))
        }
        if codes.contains("P0172") || codes.contains("P0175") || (trimsValid && (lt1 ?? 0) + (st1 ?? 0) < -15) {
            out.append(Finding(severity: .attention, title: "Running rich",
                               detail: "The computer is pulling fuel out. Long-term rich running fouls plugs and catalysts.",
                               checks: ["Leaking injector or high fuel pressure", "Contaminated/failing MAF",
                                        "Stuck-open EVAP purge valve", "Engine oil diluted with fuel"]))
        }

        // Catalyst
        if codes.contains("P0420") || codes.contains("P0430") {
            out.append(Finding(severity: .attention, title: "Catalytic converter efficiency low",
                               detail: "The downstream O2 sensor sees the converter isn't storing oxygen as well as it should. Fix any misfire or fuel-trim issue first — those often cause this code.",
                               checks: ["Check for exhaust leaks ahead of the rear O2 sensor",
                                        "Compare upstream vs. downstream O2 sensor activity (downstream should be steady)",
                                        "Confirm the rear O2 sensor isn't lazy before condemning the converter"]))
        }

        // EVAP
        if codes.contains(where: { ["P0440", "P0442", "P0455", "P0456", "P0457"].contains($0) }) {
            out.append(Finding(severity: .watch, title: "Evaporative (fuel vapour) leak",
                               detail: "Doesn't affect how the car drives but keeps the check-engine light on and fails a smog check.",
                               checks: ["Re-seat or replace the fuel cap", "Smoke-test EVAP lines, purge and vent valves"]))
        }

        // Cooling
        if let ect = live[0x05] {
            if ect > 110 {
                out.append(Finding(severity: .urgent, title: "Coolant temperature high (\(Int(ect)) °C)",
                                   detail: "Stop driving and let the engine cool. Overheating can warp heads and damage the engine.",
                                   checks: ["Coolant level (only when cold)", "Cooling fans running", "Water pump / thermostat"]))
            } else if running, let rt = live[0x1F], rt > 900, ect < 70 {
                out.append(Finding(severity: .watch, title: "Engine not reaching operating temperature",
                                   detail: "After 15+ minutes running the coolant is still below 70 °C.",
                                   checks: ["Thermostat stuck open", "Coolant temperature sensor reading low"]))
            }
        }

        // Charging / battery
        if let v = battery ?? live[0x42] {
            if running && v < 13.0 {
                out.append(Finding(severity: .attention, title: String(format: "Low charging voltage (%.1f V)", v),
                                   detail: "With the engine running the alternator should hold roughly 13.5–14.7 V.",
                                   checks: ["Alternator output and belt", "Battery terminals and ground straps"]))
            } else if !running && v < 12.2 {
                out.append(Finding(severity: .watch, title: String(format: "Battery low (%.1f V)", v),
                                   detail: "A rested battery should read about 12.6 V. Keep a battery maintainer connected during long diagnostic sessions with the ignition on.",
                                   checks: ["Charge and load-test the battery", "Check for parasitic drain"]))
            } else if running && v > 15.0 {
                out.append(Finding(severity: .attention, title: String(format: "Charging voltage high (%.1f V)", v),
                                   detail: "Overcharging can damage the battery and electronics.",
                                   checks: ["Voltage regulator / alternator"]))
            }
        }

        // Communication codes
        if dtcs.contains(where: { $0.code.hasPrefix("U") }) {
            out.append(Finding(severity: .attention, title: "Module communication fault",
                               detail: "One module lost contact with another. Often caused by low voltage, a connector, or a module that was asleep.",
                               checks: ["Check battery voltage first", "Inspect connectors/grounds for the module named in the code"]))
        }

        // Manufacturer-specific
        let mfr = dtcs.filter(\.isManufacturerSpecific)
        if !mfr.isEmpty {
            out.append(Finding(severity: .info, title: "\(mfr.count) manufacturer-specific code\(mfr.count == 1 ? "" : "s")",
                               detail: "\(mfr.map(\.code).joined(separator: ", ")) — the meaning is defined by the carmaker. Look these up in the factory service information or have the dealer read them with their tool.",
                               checks: []))
        }

        // Readiness
        if let r = readiness {
            if r.milOn && dtcs.isEmpty {
                out.append(Finding(severity: .attention, title: "Check-engine light on but no codes read",
                                   detail: "The light is commanded on by a module that didn't answer the generic request, or the code is manufacturer-specific.",
                                   checks: ["Have the full module scan done with the manufacturer's tool"]))
            }
            if r.incompleteCount > 0 {
                let names = r.monitors.filter { !$0.complete }.map(\.name).joined(separator: ", ")
                out.append(Finding(severity: .info, title: "\(r.incompleteCount) readiness monitor\(r.incompleteCount == 1 ? "" : "s") not ready",
                                   detail: "\(names). Normal right after codes were cleared or the battery was disconnected; they finish after a few days of mixed driving. Smog checks limit how many can be incomplete, so let them finish before testing.",
                                   checks: []))
            }
        }

        if out.isEmpty {
            out.append(Finding(severity: .info, title: "No problems found",
                               detail: "No generic trouble codes and the live values look normal.", checks: []))
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

import SwiftUI

// Two VW-group checks built on the measuring-block explorer (TP2.0 cars, about 2004–2014). Read-only.
//
// 1. Gateway installation list — the CAN gateway (address 19) keeps a list of the modules the car
//    should have and whether each one is talking. On many VW gateways it sits in groups 125–129,
//    shown as text such as "Engine 1" (1 = communicating, 0 = not). Group numbers and format vary,
//    so the raw groups are always shown too.
// 2. Camshaft timing values — engines report how far the camshaft timing has moved from where it
//    should be, in crankshaft degrees (°KW). Shops compare these against the factory limit to judge
//    timing-chain stretch. Group numbers vary by engine, so we search the engine's groups for °KW
//    values and let the owner save a baseline to compare with later.

struct GatewayListCard: View {
    @EnvironmentObject var s: VehicleSession

    /// Text fields from groups 125–129 that end in " 0" — modules listed but not talking.
    private var notTalking: [String] {
        guard s.explorerAddress == 0x19 else { return [] }
        return s.explorerResults.filter { (125...129).contains(Int($0.group)) }
            .flatMap(\.fields)
            .filter { $0.value == nil }
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix(" 0") || $0.hasSuffix(":0") }
    }

    private var listed: Int {
        guard s.explorerAddress == 0x19 else { return 0 }
        return s.explorerResults.filter { (125...129).contains(Int($0.group)) }.flatMap(\.fields).filter { $0.value == nil }.count
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Gateway installation list").font(.headline)
                    Spacer()
                    Button("Read gateway list") { Task { await s.exploreBlocks(address: 0x19, first: 125, last: 129) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.busy != nil || !s.isCAN || s.protocolName.contains("29-bit"))
                }
                Text("Shows which modules the gateway expects and whether each is talking. On many VW gateways each entry reads like \"ABS Brakes 1\" — 1 means communicating, 0 means not. A module that isn't talking can switch on several warning lights at once.")
                    .font(.caption).foregroundStyle(.secondary)
                if s.explorerAddress == 0x19 && s.explorerProgress == nil && listed > 0 {
                    if notTalking.isEmpty {
                        Label("Every listed module is communicating.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        ForEach(notTalking, id: \.self) { t in
                            Label("Not communicating: \(t)", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                        }
                        Text("Check that module's fuse, connector, power and ground first; low battery voltage can also knock modules offline.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if s.explorerAddress == 0x19 && s.explorerProgress == nil && !s.explorerResults.isEmpty {
                    Text("This gateway's list isn't in text form here — read the raw groups below.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CamTimingCard: View {
    @EnvironmentObject var s: VehicleSession
    @State private var baseline: [String: Double] = [:]
    @State private var baselineDate: Date?

    private struct Found: Identifiable {
        let key: String        // "093.2"
        let group: String
        let field: Int
        let value: Double
        let unit: String
        var id: String { key }
    }

    private var found: [Found] {
        guard s.explorerAddress == 0x01 else { return [] }
        return s.explorerResults.flatMap { g in
            g.fields.compactMap { f -> Found? in
                guard let v = f.value, f.unit.contains("KW") else { return nil }
                return Found(key: "\(g.groupText).\(f.index + 1)", group: g.groupText, field: f.index + 1, value: v, unit: f.unit)
            }
        }
    }

    private var baselineKey: String { "camBaseline.\(s.vin)" }

    private func loadBaseline() {
        baseline = (UserDefaults.standard.dictionary(forKey: baselineKey) as? [String: Double]) ?? [:]
        baselineDate = UserDefaults.standard.object(forKey: baselineKey + ".date") as? Date
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Camshaft timing (chain stretch)").font(.headline)
                    Spacer()
                    Button("Find timing values") { Task { await s.exploreBlocks(address: 0x01, first: 1, last: 130) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.busy != nil || !s.isCAN || s.protocolName.contains("29-bit"))
                }
                Text("Searches the engine computer's groups 001–130 for camshaft-timing values in crankshaft degrees (°KW). Run it with the engine warm and idling. Compare the value with the limit in VW's service information for your engine — on chain-driven engines a value creeping toward the limit over months suggests the chain is stretching. Save a baseline today to track it.")
                    .font(.caption).foregroundStyle(.secondary)
                if s.explorerAddress == 0x01 && s.explorerProgress == nil {
                    if found.isEmpty {
                        Text(s.explorerResults.isEmpty ? "The engine didn't return any groups." : "No crankshaft-degree values found in groups 001–130 on this engine.")
                            .foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            GridRow {
                                Text("Group.field").font(.caption.bold())
                                Text("Now").font(.caption.bold())
                                Text("Baseline").font(.caption.bold())
                                Text("Change").font(.caption.bold())
                            }
                            ForEach(found) { f in
                                GridRow {
                                    Text(f.key).monospaced()
                                    Text("\(VAGBlocks.format(f.value)) \(f.unit)").monospacedDigit()
                                    Text(baseline[f.key].map { VAGBlocks.format($0) } ?? "—").monospacedDigit()
                                    Text(baseline[f.key].map { String(format: "%+.1f", f.value - $0) } ?? "—").monospacedDigit()
                                }
                            }
                        }
                        HStack {
                            Button("Save as baseline") {
                                var d: [String: Double] = [:]
                                for f in found { d[f.key] = f.value }
                                UserDefaults.standard.set(d, forKey: baselineKey)
                                UserDefaults.standard.set(Date(), forKey: baselineKey + ".date")
                                loadBaseline()
                            }
                            if let d = baselineDate {
                                Text("Baseline from \(d.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("Not every °KW value is camshaft timing — some are ignition or injection angles. The group's other fields and VW's service information tell you which is which.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { loadBaseline() }
        .onChange(of: s.vin) { _, _ in loadBaseline() }
    }
}

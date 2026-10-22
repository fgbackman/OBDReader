import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

// MARK: - Pre-purchase check

struct InspectionView: View {
    @EnvironmentObject var s: VehicleSession
    @State private var odoText = ""

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        PageHeader(title: "Pre-Purchase Check",
                                   subtitle: "Signs of hidden problems in a used car's own records")
                        Spacer()
                        Button("Rescan") { Task { await s.fullScan() } }.disabled(s.busy != nil)
                    }

                    if let r = s.inspection {
                        Card {
                            HStack(spacing: 14) {
                                Image(systemName: Self.icon(r.worst)).font(.system(size: 34))
                                    .foregroundStyle(Self.color(r.worst))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(r.verdict).font(.title2.weight(.semibold))
                                    Text("\(r.redCount) red flag\(r.redCount == 1 ? "" : "s") · \(r.cautionCount) thing\(r.cautionCount == 1 ? "" : "s") to ask about")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Dashboard odometer")
                                TextField("reading", text: $odoText)
                                    .textFieldStyle(.roundedBorder).frame(width: 120)
                                    .onSubmit { applyOdometer() }
                                Text(s.units == .us ? "miles" : "km").foregroundStyle(.secondary)
                                Button("Compare") { applyOdometer() }
                            }
                            Text(s.liveValues[0xA6] != nil
                                 ? "Type what the instrument cluster shows. It's compared with the odometer stored in the engine computer."
                                 : "This car doesn't report an odometer over OBD-II (most cars before 2019), so the reading can't be cross-checked here.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let r = s.inspection {
                        ForEach(r.flags) { FlagRow(flag: $0) }
                    }

                    softwareCard

                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What this can't see").font(.headline)
                            Text("Accident repairs, rust, mechanical wear, service history, and faults in modules outside generic OBD-II (airbags, ABS, transmission on many cars, and on exotics the chassis, hydraulics and aero systems). For a high-value car, pair this with a pre-purchase inspection by a marque specialist and a history report.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(24)
            }
            .onAppear {
                if let km = s.dashOdometerKm {
                    odoText = String(format: "%.0f", s.units == .us ? km * 0.621371 : km)
                }
            }
        }
    }

    @ViewBuilder private var softwareCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Engine software fingerprint").font(.headline)
                if s.software.isEmpty {
                    Text("The car didn't report calibration IDs.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                        GridRow {
                            Text("Module").font(.caption.bold())
                            Text("Calibration ID").font(.caption.bold())
                            Text("Checksum (CVN)").font(.caption.bold())
                        }
                        ForEach(s.software) { sw in
                            GridRow {
                                Text(sw.ecu).monospaced()
                                Text(sw.calids.joined(separator: "\n")).monospaced().textSelection(.enabled)
                                Text(sw.cvns.isEmpty ? "—" : sw.cvns.joined(separator: "\n")).monospaced().textSelection(.enabled)
                            }
                        }
                    }
                }
                Text("Saved with every scan. If the checksum changes between scans, the engine software was rewritten — a dealer update or a tune. To check a car you're viewing for the first time, compare these with a known-stock car of the same model and year.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func applyOdometer() {
        let cleaned = odoText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let x = Double(cleaned), x > 0 else { s.dashOdometerKm = nil; return }
        s.dashOdometerKm = s.units == .us ? x / 0.621371 : x
    }

    static func color(_ l: InspectionFlag.Level) -> Color {
        switch l {
        case .red: return .red
        case .caution: return .orange
        case .info: return .blue
        case .ok: return .green
        }
    }
    static func icon(_ l: InspectionFlag.Level) -> String {
        switch l {
        case .red: return "exclamationmark.octagon.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .ok: return "checkmark.seal.fill"
        }
    }
}

struct FlagRow: View {
    let flag: InspectionFlag
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: InspectionView.icon(flag.level))
                    .foregroundStyle(InspectionView.color(flag.level))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(flag.title).font(.headline)
                        Spacer()
                        Text(flag.level.label).font(.caption.bold()).foregroundStyle(InspectionView.color(flag.level))
                    }
                    Text(flag.detail).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Turbo & torque

struct Tile: Identifiable {
    let id: String
    let name: String
    let text: String
    let history: [Double]
}

struct TileView: View {
    let tile: Tile
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(tile.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(tile.text)
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Sparkline(values: tile.history).frame(height: 24)
            }
        }
    }
}

struct TurboView: View {
    @EnvironmentObject var s: VehicleSession

    static let widebandPIDs: [UInt8] = Array(UInt8(0x24)...UInt8(0x2B)) + Array(UInt8(0x34)...UInt8(0x3B))
    static let focusPIDs: [UInt8] = PIDs.performancePIDs + [0x03, 0x44, 0x0C, 0x33] + widebandPIDs

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        PageHeader(title: "Turbo & Torque",
                                   subtitle: "Boost, turbo speed and temperatures, exhaust temps, torque and mixture")
                        Spacer()
                        Button(s.isLive ? "Stop" : "Start live data") {
                            if s.isLive { s.stopLive() } else { s.startLive() }
                        }
                    }
                    if !s.isLive {
                        Text("Start live data to see readings.").foregroundStyle(.secondary)
                    }
                    let supported = Set(s.supportedPIDs)
                    if Self.focusPIDs.filter({ supported.contains($0) && $0 != 0x0C && $0 != 0x33 && $0 != 0x0B }).isEmpty {
                        Card {
                            Text("This car doesn't report turbo, torque or wideband sensors over generic OBD-II. These PIDs were added to the standard around 2010 and many cars — including older exotics — only expose them to the manufacturer's tool.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    section("Torque & power", torqueTiles)
                    section("Boost", boostTiles)
                    section("Boost control", tiles([0x70, 0x72]))
                    section("Turbochargers", tiles([0x74, 0x75, 0x76, 0x77]))
                    section("Exhaust", tiles([0x78, 0x79, 0x73]))
                    mixtureSection
                    Text("Torque is the engine computer's own estimate; power is calculated from it and RPM, so treat both as indicative. Exhaust temperatures over roughly 950 °C (1,740 °F) on a gasoline engine under sustained load are worth backing off for.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .onAppear { s.setFocus("turbo", Self.focusPIDs) }
            .onDisappear { s.setFocus("turbo", nil) }
        }
    }

    @ViewBuilder private func section(_ title: String, _ list: [Tile]) -> some View {
        if !list.isEmpty {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(list) { TileView(tile: $0) }
            }
        }
    }

    /// Tiles for simple PIDs and every fitted channel of multi-sensor PIDs.
    private func tiles(_ pids: [UInt8]) -> [Tile] {
        var out: [Tile] = []
        for pid in pids {
            guard let def = PIDs.def(pid) else { continue }
            if def.channels.isEmpty {
                if let v = s.liveValues[pid] {
                    out.append(Tile(id: String(format: "%02X", Int(pid)), name: def.name,
                                    text: def.format(v, s.units), history: s.history[pid] ?? []))
                }
            } else {
                for ch in def.channels {
                    if let v = s.extValues[ch.key] {
                        out.append(Tile(id: ch.key, name: ch.name, text: ch.kind.format(v, s.units),
                                        history: s.extHistory[ch.key] ?? []))
                    }
                }
            }
        }
        return out
    }

    private var torqueTiles: [Tile] {
        var out = tiles([0x61, 0x62])
        if let ref = s.liveValues[0x63], let pct = s.liveValues[0x62] {
            let nm = ref * pct / 100
            let hist = (s.history[0x62] ?? []).map { ref * $0 / 100 }
            out.append(Tile(id: "torque", name: "Engine torque (estimated)",
                            text: UnitKind.torque.format(nm, s.units), history: hist))
            if let rpm = s.liveValues[0x0C] {
                let kw = nm * rpm / 9549
                out.append(Tile(id: "power", name: "Power (estimated)",
                                text: s.units == .us ? String(format: "%.0f hp", kw * 1.341) : String(format: "%.0f kW", kw),
                                history: []))
            }
            out.append(Tile(id: "ref", name: "Reference (max) torque",
                            text: UnitKind.torque.format(ref, s.units), history: []))
        }
        return out
    }

    private var boostTiles: [Tile] {
        var out: [Tile] = []
        let baro = s.liveValues[0x33] ?? 101.3
        func boost(_ kpa: Double) -> String {
            let g = kpa - baro
            return s.units == .us ? String(format: "%+.1f psi", g * 0.145038) : String(format: "%+.2f bar", g / 100)
        }
        if let a = s.extValues["87.A"] {
            out.append(Tile(id: "boostA", name: "Boost A (manifold − barometric)", text: boost(a),
                            history: s.extHistory["87.A"] ?? []))
            if let b = s.extValues["87.B"] {
                out.append(Tile(id: "boostB", name: "Boost B (manifold − barometric)", text: boost(b),
                                history: s.extHistory["87.B"] ?? []))
            }
        } else if let m = s.liveValues[0x0B] {
            out.append(Tile(id: "boost0B", name: "Boost (manifold − barometric)", text: boost(m),
                            history: s.history[0x0B] ?? []))
        }
        return out + tiles([0x6F])
    }

    @ViewBuilder private var mixtureSection: some View {
        let wide = tiles(Self.widebandPIDs) + tiles([0x44])
        if s.liveValues[0x03] != nil || !wide.isEmpty {
            Text("Mixture").font(.headline)
            if let fs = s.liveValues[0x03] {
                let closed = PIDs.closedLoop(fs) == true
                Label(PIDs.fuelSystemText(fs), systemImage: closed ? "arrow.triangle.2.circlepath" : "arrow.right")
                    .foregroundStyle(closed ? Color.green : Color.orange)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(wide) { TileView(tile: $0) }
            }
            Text("λ = 1.00 is the ideal mixture; below 1 is rich (normal under full throttle), above 1 is lean. Fuel trims are only judged in closed loop.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Track day

struct TrackView: View {
    @EnvironmentObject var s: VehicleSession

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Track", subtitle: "GPS lap timer, g-meter and a data log you can export")
                    Label("Closed course or track only. Set it up before you go out — don't touch the Mac while driving.",
                          systemImage: "flag.checkered").foregroundStyle(.orange)

                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                if let p = s.gpsPosition {
                                    Label(String(format: "GPS fix %.5f, %.5f", p.lat, p.lon), systemImage: "location.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Label(s.gpsConnected ? "Waiting for a GPS fix…" : "No GPS — lap timing needs a USB GPS receiver (Connection page). g-forces still work from OBD speed (braking/acceleration only).",
                                          systemImage: "location.slash").foregroundStyle(.orange)
                                }
                            }
                            HStack {
                                Button("Set start/finish here") { s.setStartLineHere() }
                                    .disabled(s.gpsPosition == nil)
                                    .help("Park on the start/finish line and press this")
                                if let sl = s.track.startLine {
                                    Text(String(format: "Start/finish: %.5f, %.5f", sl.lat, sl.lon))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if s.trackActive {
                                    Button("Stop session") { s.stopTrack() }
                                } else {
                                    Button("Start session") { s.startTrack() }.buttonStyle(.borderedProminent)
                                }
                                Button("Reset") { s.resetTrack() }.disabled(s.trackActive)
                                Button("Export CSV…") {
                                    saveText(s.trackCSV(), name: "Track session.csv", type: .commaSeparatedText)
                                }
                                .disabled(s.track.points.isEmpty || s.trackActive)
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 14) {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                                    Readout(label: "Lap \(max(s.track.currentLap, 1))",
                                            value: s.track.currentLapTime.map { Self.lapTime($0) } ?? "—")
                                }
                                HStack(spacing: 28) {
                                    Readout(label: "Last lap", value: s.track.lastLap.map { Self.lapTime($0.time) } ?? "—")
                                    Readout(label: "Best lap", value: s.track.bestLap.map { Self.lapTime($0.time) } ?? "—")
                                }
                                HStack(spacing: 28) {
                                    Readout(label: "Peak lateral", value: String(format: "%.2f g", s.track.peakGLat))
                                    Readout(label: "Peak braking", value: String(format: "%.2f g", s.track.peakBrake))
                                    Readout(label: "Peak accel", value: String(format: "%.2f g", s.track.peakAccel))
                                }
                            }
                        }
                        Card {
                            VStack(spacing: 6) {
                                Text("g-meter").font(.caption).foregroundStyle(.secondary)
                                GMeter(points: s.track.points.suffix(60).map { ($0.gLat, $0.gLong) },
                                       current: (s.track.gLat, s.track.gLong))
                                    .frame(width: 200, height: 200)
                            }
                        }
                        .frame(width: 240)
                    }

                    if s.track.points.contains(where: { $0.lat != nil }) {
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Track map").font(.caption).foregroundStyle(.secondary)
                                TrackMap(points: s.track.points, start: s.track.startLine).frame(height: 260)
                            }
                        }
                    }

                    if !s.track.laps.isEmpty {
                        Text("Laps").font(.headline)
                        Card {
                            Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 5) {
                                GridRow {
                                    Text("Lap").font(.caption.bold())
                                    Text("Time").font(.caption.bold())
                                    Text("Top speed").font(.caption.bold())
                                    Text("Max lateral").font(.caption.bold())
                                }
                                ForEach(s.track.laps) { lap in
                                    GridRow {
                                        Text("\(lap.number)")
                                        Text(Self.lapTime(lap.time)).monospacedDigit()
                                            .foregroundStyle(lap.id == s.track.bestLap?.id ? Color.purple : Color.primary)
                                        Text(UnitKind.speed.format(lap.maxKmh, s.units)).monospacedDigit()
                                        Text(String(format: "%.2f g", lap.maxGLat)).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }

                    Text("Lap timing uses the closest GPS point to your start/finish within \(Int(TrackSession.gateRadius)) m; a 10 Hz receiver gives times to about ±0.05 s, a 1 Hz one only to about ±0.5 s. Lateral g comes from GPS heading changes and longitudinal g from speed changes, both smoothed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
    }

    static func lapTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let sec = t - Double(m * 60)
        return String(format: "%d:%06.3f", m, sec)
    }
}

struct GMeter: View {
    let points: [(Double, Double)]       // (lateral, longitudinal)
    let current: (Double, Double)
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = min(size.width, size.height) / 2 / 1.6          // 1.6 g at the edge
            for g in [0.5, 1.0, 1.5] {
                let r = g * scale
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(.secondary.opacity(g == 1.0 ? 0.5 : 0.25)), lineWidth: 1)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: c.x, y: 0)); cross.addLine(to: CGPoint(x: c.x, y: size.height))
            cross.move(to: CGPoint(x: 0, y: c.y)); cross.addLine(to: CGPoint(x: size.width, y: c.y))
            ctx.stroke(cross, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
            // Braking plots up (toward the front of the car), acceleration down, right turns right.
            func pt(_ lat: Double, _ long: Double) -> CGPoint {
                CGPoint(x: c.x + lat * scale, y: c.y + long * scale)
            }
            for (i, p) in points.enumerated() {
                let q = pt(p.0, p.1)
                let a = Double(i + 1) / Double(max(points.count, 1))
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4)),
                         with: .color(.accentColor.opacity(0.15 + 0.5 * a)))
            }
            let q = pt(current.0, current.1)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 7, y: q.y - 7, width: 14, height: 14)), with: .color(.orange))
        }
    }
}

struct TrackMap: View {
    let points: [TrackPoint]
    let start: (lat: Double, lon: Double)?
    var body: some View {
        Canvas { ctx, size in
            let pts = points.compactMap { p -> (Double, Double, Int)? in
                guard let la = p.lat, let lo = p.lon else { return nil }
                return (la, lo, p.lap)
            }
            guard pts.count > 1 else { return }
            let lats = pts.map { $0.0 }, lons = pts.map { $0.1 }
            let midLat = (lats.min()! + lats.max()!) / 2
            let k = cos(midLat * .pi / 180)          // shrink longitude so the shape isn't stretched
            let minX = lons.min()! * k, maxX = lons.max()! * k
            let minY = lats.min()!, maxY = lats.max()!
            let span = max(maxX - minX, maxY - minY, 1e-6)
            let w = Double(size.width), h = Double(size.height)
            let scale: Double = min(w, h) * 0.9 / span
            let ox: Double = (w - (maxX - minX) * scale) / 2
            let oy: Double = (h - (maxY - minY) * scale) / 2
            func pt(_ la: Double, _ lo: Double) -> CGPoint {
                let x: Double = ox + (lo * k - minX) * scale
                let y: Double = h - (oy + (la - minY) * scale)
                return CGPoint(x: x, y: y)
            }
            let lastLap = pts.last!.2
            var old = Path(), cur = Path()
            for (i, p) in pts.enumerated() {
                let q = pt(p.0, p.1)
                let path = p.2 == lastLap
                if path {
                    if cur.isEmpty || i == 0 { cur.move(to: q) } else { cur.addLine(to: q) }
                } else {
                    if old.isEmpty { old.move(to: q) } else { old.addLine(to: q) }
                }
            }
            ctx.stroke(old, with: .color(.secondary.opacity(0.4)), lineWidth: 1.5)
            ctx.stroke(cur, with: .color(.accentColor), lineWidth: 2.5)
            if let s = start {
                let q = pt(s.lat, s.lon)
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(.green))
            }
            let q = pt(pts.last!.0, pts.last!.1)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(.orange))
        }
    }
}

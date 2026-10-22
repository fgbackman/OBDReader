import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared bits

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

struct NotConnectedHint: View {
    var body: some View {
        ContentUnavailableView("Not connected", systemImage: "cable.connector.slash",
                               description: Text("Connect to the adapter (or the simulator) on the Connection page."))
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Connection

struct ConnectionView: View {
    /// ELM327 ATSP values. "0" searches automatically (by sending requests).
    static let protocolChoices: [(String, String)] = [
        ("0", "Automatic"),
        ("6", "CAN 11-bit, 500 kbaud (most cars)"),
        ("7", "CAN 29-bit, 500 kbaud"),
        ("8", "CAN 11-bit, 250 kbaud"),
        ("9", "CAN 29-bit, 250 kbaud"),
        ("B", "Ford MS-CAN (11-bit, 125 kbaud)"),
        ("3", "ISO 9141-2 (K-line)"),
        ("4", "ISO 14230 KWP (slow init)"),
        ("5", "ISO 14230 KWP (fast init)"),
        ("1", "SAE J1850 PWM"),
        ("2", "SAE J1850 VPW"),
    ]

    @EnvironmentObject var s: VehicleSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Connection", subtitle: "USB OBD-II adapter → car's diagnostic port")

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Use simulator (no car needed)", isOn: $s.useSimulator)
                            .disabled(s.isConnected)
                        HStack {
                            Picker("Serial port", selection: $s.selectedPort) {
                                if s.ports.isEmpty { Text("No adapters found").tag("") }
                                ForEach(s.ports, id: \.self) { Text($0).tag($0) }
                            }
                            .disabled(s.useSimulator || s.isConnected)
                            Button { s.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                                .help("Look for adapters again")
                                .disabled(s.isConnected)
                        }
                        HStack(spacing: 16) {
                            Picker("Protocol", selection: $s.protocolChoice) {
                                ForEach(ConnectionView.protocolChoices, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .frame(maxWidth: 380)
                            Toggle("Listen only (CAN tap)", isOn: $s.listenOnly)
                                .help("Connect without sending anything to the car — for listening on a CAN tap. Codes and live data are unavailable on this connection.")
                        }
                        .disabled(s.isConnected || s.status == .connecting)
                        if s.listenOnly && s.protocolChoice == "0" {
                            Text("Listen only needs a fixed protocol; CAN 11-bit 500 kbaud will be used.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if s.isConnected {
                                Button("Disconnect") { Task { await s.disconnect() } }
                            } else if s.status == .connecting {
                                Button("Stop", role: .destructive) { s.cancelConnect() }
                                    .keyboardShortcut(.cancelAction)
                                ProgressView().controlSize(.small)
                                if let b = s.busy { Text(b).font(.callout).foregroundStyle(.secondary) }
                            } else {
                                Button("Connect") { Task { await s.connect() } }
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(!s.useSimulator && s.selectedPort.isEmpty)
                            }
                        }
                        if case .failed(let msg) = s.status {
                            Label(msg, systemImage: "xmark.octagon").foregroundStyle(.red)
                        }
                    }
                }

                if s.isConnected {
                    Card {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow { Text("Adapter").foregroundStyle(.secondary); Text(s.adapterID) }
                            GridRow { Text("Protocol").foregroundStyle(.secondary); Text(s.protocolName) }
                            if s.connectedListenOnly {
                                GridRow { Text("Mode").foregroundStyle(.secondary); Text("Listen only — nothing is sent to the car").foregroundStyle(.orange) }
                            }
                            GridRow { Text("Sensors supported").foregroundStyle(.secondary); Text("\(s.supportedPIDs.count) PIDs") }
                            if let b = s.battery {
                                GridRow { Text("Battery").foregroundStyle(.secondary); Text(String(format: "%.1f V", b)) }
                            }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Use a GPS receiver for speed (optional)", isOn: $s.useGPS)
                        Text("Reads real speed above the OBD-II 158 mph ceiling and times runs more precisely. Any USB NMEA receiver works; a 5–10 Hz one is best. Plug it in separately from the OBD adapter.")
                            .font(.callout).foregroundStyle(.secondary)
                        if s.useGPS {
                            HStack {
                                Picker("GPS port", selection: $s.gpsPort) {
                                    Text("Select…").tag("")
                                    ForEach(s.ports, id: \.self) { Text($0).tag($0) }
                                }
                                .disabled(s.gpsConnected)
                                Picker("Baud", selection: $s.gpsBaud) {
                                    ForEach(GPSReceiver.bauds, id: \.self) { Text("\($0)").tag($0) }
                                }
                                .frame(width: 130)
                                .disabled(s.gpsConnected)
                                if s.gpsConnected {
                                    Button("Stop GPS") { s.stopGPS() }
                                } else {
                                    Button("Start GPS") { s.startGPS() }.disabled(s.gpsPort.isEmpty)
                                }
                            }
                            if s.gpsConnected {
                                if let r = s.gpsReading {
                                    Label(String(format: "GPS fix: %.0f mph · %d satellites", r.kmh * 0.621371, r.satellites),
                                          systemImage: "location.fill").foregroundStyle(.green)
                                } else {
                                    Label("Waiting for a GPS fix…", systemImage: "location").foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .font(.callout)
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Record & replay").font(.headline)
                        Toggle("Record the next session", isOn: $s.recordNextSession)
                            .disabled(s.isConnected || s.status == .connecting)
                        Text("Saves every request and the car's exact replies until you disconnect. Open a recording later — on any Mac — and every page works as if the car were connected. Handy for sharing a problem with a mechanic or developing without the car.")
                            .foregroundStyle(.secondary)
                        if let r = s.replaying {
                            Label("Replaying \(r)", systemImage: "play.circle.fill").foregroundStyle(.blue)
                        } else if s.isRecordingSession {
                            Label("Recording — disconnect to save", systemImage: "record.circle").foregroundStyle(.red)
                        }
                        HStack {
                            Button("Open recording…") { s.openRecording() }
                                .disabled(s.isConnected || s.status == .connecting)
                            Button("Show recordings in Finder") { s.revealRecordings() }
                            if let u = s.lastRecordingURL {
                                Text("Last saved: \(u.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.callout)
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How to hook up").font(.headline)
                        Text("1. Plug the adapter into the car's OBD-II port (a 16-pin socket under the dashboard, usually driver's side — check the owner's manual for its exact spot).")
                        Text("2. Connect the adapter's USB cable to the Mac. On a USB-C-only MacBook use a USB-C to USB-A adapter.")
                        Text("3. Turn the ignition ON. The engine can stay off for reading codes; start it for live data.")
                        Text("4. Pick the port that looks like /dev/cu.usbserial-… and press Connect.")
                        Text("Tip: for long sessions with the ignition on and engine off, connect a battery maintainer.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var s: VehicleSession
    @State private var choosing = false

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        PageHeader(title: "Live Dashboard", subtitle: "Real-time sensor data from the engine computer")
                        Spacer()
                        Button(s.isLive ? "Stop" : "Start live data") {
                            if s.isLive { s.stopLive() } else { s.startLive() }
                        }
                        .keyboardShortcut("l", modifiers: .command)
                        Button {
                            s.toggleRecording()
                        } label: {
                            Label(s.isRecording ? "Stop recording (\(s.recordedCount))" : "Record",
                                  systemImage: s.isRecording ? "stop.circle.fill" : "record.circle")
                        }
                        .tint(s.isRecording ? .red : nil)
                        Button("Save CSV…") {
                            saveText(s.recordingCSV(), name: "OBD log.csv", type: .commaSeparatedText)
                        }
                        .disabled(s.recordedCount == 0 || s.isRecording)
                        Button("Sensors…") { choosing = true }
                            .popover(isPresented: $choosing) { PIDChooser().environmentObject(s).frame(width: 320, height: 420) }
                    }
                    if s.isLive {
                        HStack(spacing: 14) {
                            Text(String(format: "%.1f updates per second", s.samplesPerSecond))
                            if s.speedSource != .obd {
                                Label("Speed from \(s.speedSource.rawValue)", systemImage: s.speedSource == .gps ? "location.fill" : "function")
                                    .foregroundStyle(.blue)
                            } else if s.speedLearnReady {
                                Text("RPM speed estimate ready for above 158 mph").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(s.visibleDashboardPIDs, id: \.self) { pid in
                            if let def = PIDs.def(pid) {
                                GaugeCard(def: def, value: s.liveValues[pid], history: s.history[pid] ?? [], units: s.units,
                                          extra: s.channelSummary(def))
                            }
                        }
                    }
                    if s.visibleDashboardPIDs.isEmpty {
                        Text("None of the chosen sensors are supported by this car. Use Sensors… to pick others.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        }
    }
}

struct GaugeCard: View {
    let def: PIDDef
    let value: Double?
    let history: [Double]
    let units: UnitSystem
    /// Second reading packed in the same PID (O2 trim, wideband voltage/current).
    var extra: String? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(def.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(value.map { def.format($0, units) } ?? "—")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                if let extra { Text(extra).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Sparkline(values: history).frame(height: 28)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            if values.count > 1, let lo = values.min(), let hi = values.max() {
                let span = max(hi - lo, 1e-9)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = g.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = g.size.height * (1 - CGFloat((v - lo) / span))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

struct PIDChooser: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        List {
            Section("Sensors this car supports") {
                ForEach(PIDs.all.filter { $0.onDashboard && s.supportedPIDs.contains($0.pid) }) { def in
                    Toggle(def.name, isOn: Binding(
                        get: { s.dashboardPIDs.contains(def.pid) },
                        set: { on in
                            if on { s.dashboardPIDs.append(def.pid) }
                            else { s.dashboardPIDs.removeAll { $0 == def.pid } }
                        }))
                }
            }
        }
    }
}

// MARK: - Trouble codes

struct CodesView: View {
    @EnvironmentObject var s: VehicleSession
    @State private var confirmClear = false

    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        PageHeader(title: "Trouble Codes", subtitle: "Generic OBD-II codes from every module that answered")
                        Spacer()
                        Button("Read again") { Task { await s.fullScan() } }.disabled(s.busy != nil)
                        Button("Clear codes…", role: .destructive) { confirmClear = true }
                            .disabled(s.busy != nil)
                    }

                    if s.dtcs.isEmpty {
                        Card { Label("No trouble codes reported.", systemImage: "checkmark.seal").foregroundStyle(.green) }
                    }
                    ForEach([DTCKind.stored, .pending, .permanent], id: \.self) { kind in
                        let list = s.dtcs.filter { $0.kind == kind }
                        if !list.isEmpty {
                            Text("\(kind.rawValue) (\(list.count))").font(.headline)
                            ForEach(list) { DTCRow(dtc: $0) }
                        }
                    }

                    if let code = s.freezeFrameDTC, !s.freezeFrame.isEmpty {
                        Text("Freeze frame — conditions when \(code) was set").font(.headline).padding(.top, 8)
                        Card {
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                                ForEach(Array(s.freezeFrame.enumerated()), id: \.offset) { _, row in
                                    GridRow {
                                        Text(row.0.name).foregroundStyle(.secondary)
                                        Text(row.0.format(row.1, s.units)).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .confirmationDialog("Clear all trouble codes?", isPresented: $confirmClear) {
                Button("Clear codes", role: .destructive) { Task { await s.clearCodes() } }
            } message: {
                Text("This turns off the check-engine light, erases freeze-frame data and resets all readiness monitors. The car will need several days of driving before it can pass a smog check. If the fault is still there the code will come back. Export a report first if you want a record.")
            }
        }
    }
}

struct DTCRow: View {
    let dtc: DTC
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Text(dtc.code)
                    .font(.system(.title2, design: .monospaced).bold())
                    .foregroundStyle(color)
                    .frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(dtc.description).font(.body.weight(.medium))
                    Text("\(dtc.system) · reported by ECU \(dtc.ecu)\(dtc.isManufacturerSpecific ? " · manufacturer-specific" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let c = dtc.causes {
                        Text("Common causes: \(c)").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Text(dtc.kind.rawValue).font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.15)))
            }
        }
    }
    private var color: Color {
        switch dtc.kind {
        case .stored: return .red
        case .pending: return .orange
        case .permanent: return .purple
        }
    }
}

// MARK: - Diagnosis

struct DiagnosisView: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "Diagnosis",
                               subtitle: "What the codes and live data suggest — leads to check, not a final verdict")
                    if let t = s.lastScan {
                        Text("Based on the scan at \(t.formatted(date: .omitted, time: .shortened)). Press Rescan after a test drive to refresh.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(s.findings) { FindingCard(f: $0) }
                }
                .padding(24)
            }
        }
    }
}

struct FindingCard: View {
    let f: Finding
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(f.title).font(.headline)
                    Spacer()
                    Text(f.severity.label).font(.caption.bold()).foregroundStyle(color)
                }
                Text(f.detail).foregroundStyle(.secondary)
                if !f.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Things to check").font(.caption.bold())
                        ForEach(f.checks, id: \.self) { Text("• \($0)").font(.callout) }
                    }
                }
            }
        }
    }
    private var color: Color {
        switch f.severity {
        case .urgent: return .red
        case .attention: return .orange
        case .watch: return .yellow
        case .info: return .blue
        }
    }
    private var icon: String {
        switch f.severity {
        case .urgent: return "exclamationmark.octagon.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .watch: return "eye.fill"
        case .info: return "info.circle.fill"
        }
    }
}

// MARK: - Readiness

struct ReadinessView: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        if !s.isConnected { NotConnectedHint() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(title: "Readiness", subtitle: "Emissions self-tests the car has finished since codes were last cleared")
                    if let r = s.readiness {
                        Card {
                            HStack {
                                Image(systemName: "engine.combustion.fill")
                                    .foregroundStyle(r.milOn ? .orange : .green).font(.title)
                                VStack(alignment: .leading) {
                                    Text("Check-engine light: \(r.milOn ? "ON" : "off")").font(.headline)
                                    Text("\(r.dtcCount) confirmed emissions code\(r.dtcCount == 1 ? "" : "s") · \(r.isDiesel ? "diesel" : "gasoline") monitors")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(r.monitors) { m in
                            HStack {
                                Image(systemName: m.complete ? "checkmark.circle.fill" : "clock.fill")
                                    .foregroundStyle(m.complete ? .green : .orange)
                                Text(m.name)
                                Spacer()
                                Text(m.complete ? "Complete" : "Not ready").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                        }
                    } else {
                        Text("The car didn't report readiness status.").foregroundStyle(.secondary)
                    }
                    if let r = s.readiness { DriveCycleCoachSection(readiness: r, thisDrive: s.driveCycle) }
                    if let d = s.driveCycle, !d.monitors.isEmpty { DriveCycleSection(readiness: d) }
                    if let ipt = s.inUsePerformance, !ipt.monitors.isEmpty { InUsePerformanceSection(ipt: ipt) }
                }
                .padding(24)
            }
        }
    }
}

// MARK: - Vehicle info

struct VehicleInfoView: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Vehicle Info", subtitle: "Identification reported over OBD-II")
                if s.isConnected {
                    Card {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow { Text("VIN").foregroundStyle(.secondary)
                                Text(s.vin.isEmpty ? "not reported" : s.vin).font(.body.monospaced()).textSelection(.enabled) }
                            GridRow { Text("Calibration ID").foregroundStyle(.secondary)
                                Text(s.calibrationIDs.isEmpty ? "—" : s.calibrationIDs.joined(separator: "\n")).font(.body.monospaced()) }
                            GridRow { Text("Software checksum").foregroundStyle(.secondary)
                                Text(s.software.flatMap(\.cvns).isEmpty ? "—" : s.software.map { "\($0.ecu): \($0.cvns.joined(separator: ", "))" }.joined(separator: "\n"))
                                    .font(.body.monospaced()) }
                            GridRow { Text("ECU name").foregroundStyle(.secondary)
                                Text(s.ecuNames.isEmpty ? "—" : s.ecuNames.joined(separator: "\n")) }
                            if let std = PIDs.obdStandardText(s.liveValues[0x1C]) {
                                GridRow { Text("OBD standard").foregroundStyle(.secondary); Text(std) }
                            }
                            if let hrs = s.liveValues[0x7F] {
                                GridRow { Text("Engine run time").foregroundStyle(.secondary); Text(String(format: "%.0f hours", hrs)) }
                            }
                            if let ft = PIDs.fuelTypeText(s.liveValues[0x51]) {
                                GridRow { Text("Fuel type").foregroundStyle(.secondary); Text(ft) }
                            }
                            if let layout = s.profile?.engineLayout {
                                GridRow { Text("Engine").foregroundStyle(.secondary); Text(layout) }
                            }
                            if let odo = s.liveValues[0xA6] {
                                GridRow { Text("Odometer (ECU)").foregroundStyle(.secondary); Text(UnitKind.distance.format(odo, s.units)) }
                            }
                            GridRow { Text("Protocol").foregroundStyle(.secondary); Text(s.protocolName) }
                            GridRow { Text("Adapter").foregroundStyle(.secondary); Text(s.adapterID) }
                        }
                    }
                }
                if let r = s.sensorRanges {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sensor ranges reported by the car").font(.headline)
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                                if let v = r.maxLambda { GridRow { Text("Wideband O2 λ max").foregroundStyle(.secondary); Text(VAGBlocks.format(v)) } }
                                if let v = r.maxO2Volts { GridRow { Text("Wideband O2 voltage max").foregroundStyle(.secondary); Text("\(VAGBlocks.format(v)) V") } }
                                if let v = r.maxO2mA { GridRow { Text("Wideband O2 current max").foregroundStyle(.secondary); Text("\(VAGBlocks.format(v)) mA") } }
                                if let v = r.maxMAPkPa { GridRow { Text("Manifold pressure max").foregroundStyle(.secondary); Text("\(VAGBlocks.format(v)) kPa") } }
                                if let v = r.maxMAF { GridRow { Text("Air flow max").foregroundStyle(.secondary); Text("\(VAGBlocks.format(v)) g/s") } }
                            }
                            if r.warnings.isEmpty {
                                Label("Matches the standard ranges the app uses.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                ForEach(r.warnings, id: \.self) { w in
                                    Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
                if s.profile != nil { RecallsSection() }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About exotic cars (Bugatti and similar)").font(.headline)
                        Text("Every car sold in the US since 1996 must answer standard OBD-II requests, so this app reads emissions-related codes, the check-engine light, readiness, freeze frame, VIN and live engine data on a Veyron or Chiron the same way it does on any other car.")
                        Text("Non-emissions systems (chassis, airbags, body, hydraulics, the active aero and so on) aren't covered by the generic standard. The All Modules page, the TP2.0 scan and Measuring Blocks read many of them on VW-group cars; anything they can't reach needs the factory tool at an authorised service centre — export a report here first so they can see what you found.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PageHeader(title: "Adapter Log", subtitle: "Every command sent to the adapter and its reply")
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.log.joined(separator: "\n"), forType: .string)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(s.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: s.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding(24)
    }
}

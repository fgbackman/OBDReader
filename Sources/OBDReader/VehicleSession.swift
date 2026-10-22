import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class VehicleSession: ObservableObject {
    enum Status: Equatable {
        case disconnected, connecting, connected
        case failed(String)
    }

    enum CrankPhase: Equatable {
        case idle, resting, waitingForStart, running, done
        case failed(String)
    }

    let garage: GarageStore
    init(garage: GarageStore) { self.garage = garage }

    // Connection
    @Published var ports: [String] = SerialTransport.availablePorts()
    @Published var selectedPort: String = SerialTransport.availablePorts().first ?? ""
    @Published var useSimulator = false
    /// ATSP value for the next connection: "0" = automatic search.
    @Published var protocolChoice: String = UserDefaults.standard.string(forKey: "protocolChoice") ?? "0" {
        didSet { UserDefaults.standard.set(protocolChoice, forKey: "protocolChoice") }
    }
    /// Next connection is listen-only (for the CAN tap): nothing is ever sent to the car.
    /// Not remembered between launches, so a normal connection is always the default.
    @Published var listenOnly = false
    @Published private(set) var connectedListenOnly = false
    /// The car speaks OBD on UDS (SAE J1979-2).
    @Published private(set) var obdOnUDS = false
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var adapterID = ""
    @Published private(set) var protocolName = ""
    @Published private(set) var isCAN = false
    @Published private(set) var battery: Double?
    @Published private(set) var busy: String?           // short description of current work

    // Car profile (Garage)
    @Published private(set) var profile: CarProfile?

    // Scan data
    @Published private(set) var supportedPIDs: [UInt8] = []
    @Published private(set) var dtcs: [DTC] = []
    @Published private(set) var readiness: Readiness?
    @Published private(set) var freezeFrameDTC: String?
    @Published private(set) var freezeFrame: [(PIDDef, Double)] = []
    @Published private(set) var vin = ""
    @Published private(set) var calibrationIDs: [String] = []
    @Published private(set) var ecuNames: [String] = []
    @Published private(set) var tests: [TestResult] = []
    @Published private(set) var testsSupported: Bool?
    @Published private(set) var legacyTests: [LegacyTestResult] = []      // pre-CAN Service 06
    @Published private(set) var driveCycle: Readiness?                     // PID 41
    @Published private(set) var sensorRanges: SensorRanges?              // PIDs 4F / 50
    @Published private(set) var inUsePerformance: InUsePerformance?        // Service 09 / 08
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var smog: SmogVerdict?
    @Published private(set) var lastScan: Date?
    @Published private(set) var log: [String] = []
    @Published var units: UnitSystem = UnitSystem(rawValue: UserDefaults.standard.string(forKey: "units") ?? "") ?? .us {
        didSet { UserDefaults.standard.set(units.rawValue, forKey: "units"); refreshInspection() }
    }

    // Pre-purchase inspection & engine-software fingerprint
    @Published private(set) var software: [SoftwareID] = []
    @Published private(set) var vins: [String: String] = [:]        // ECU → VIN it reports
    @Published private(set) var inspection: PrePurchaseReport?
    /// Dashboard odometer typed in by the user, in km (compared with the ECU's own odometer).
    @Published var dashOdometerKm: Double? { didSet { refreshInspection() } }
    private(set) var previousScan: ScanRecord?

    // Multi-sensor readings (turbo A/B, exhaust temps…) by channel key, e.g. "74.A"
    @Published private(set) var extValues: [String: Double] = [:]
    @Published private(set) var extHistory: [String: [Double]] = [:]
    /// Extra PIDs a page wants in the live loop while it's on screen.
    private var focus: [String: [UInt8]] = [:]
    func setFocus(_ page: String, _ pids: [UInt8]?) { focus[page] = pids }

    // Track day
    @Published private(set) var track = TrackSession()
    @Published private(set) var trackActive = false

    // Record & replay
    @Published var recordNextSession = false

    // Custom manufacturer readings (CustomPID.swift)
    @Published private(set) var customValues: [UUID: Double] = [:]
    @Published private(set) var customErrors: [UUID: String] = [:]
    @Published private(set) var customHistory: [UUID: [Double]] = [:]
    @Published private(set) var customLive = false
    private var lastCustomRead = Date.distantPast

    // Engine health indicators (Health.swift)
    @Published private(set) var health = EngineHealth()
    func resetHealth() { health.reset() }

    // All-module fault codes (ModuleScan.swift)
    @Published private(set) var moduleReports: [ModuleReport] = []
    @Published private(set) var lastModuleScan: Date?
    private var responders: [String] = []          // ECUs that answered the standard requests

    // Logs imported from other tools (VCDS measuring blocks) — see ImportedLog.swift
    @Published var importedLogs: [ImportedLog] = []
    @Published var importFailures: [String] = []
    @Published var autoScans: [AutoScanReport] = []
    @Published private(set) var replaying: String?
    @Published private(set) var lastRecordingURL: URL?
    private var recorder: RecordingTransport?
    var recorderCount: Int { recorder?.count ?? 0 }
    var isRecordingSession: Bool { recorder != nil }

    // Live data
    @Published private(set) var liveValues: [UInt8: Double] = [:]
    @Published private(set) var history: [UInt8: [Double]] = [:]      // sparkline buffers
    @Published private(set) var isLive = false
    @Published private(set) var samplesPerSecond = 0.0
    @Published var dashboardPIDs: [UInt8] = PIDs.dashboardDefaults {
        didSet {
            guard var p = profile, p.dashboardPIDs != dashboardPIDs else { return }
            p.dashboardPIDs = dashboardPIDs
            saveProfile(p)
        }
    }
    private var sampleTimes: [Date] = []

    // Drive features
    @Published private(set) var trip = TripComputer()
    @Published private(set) var perf = PerformanceTimer()
    @Published private(set) var perfRuns: [PerfRun] = []
    @Published private(set) var alertBanner: String?
    @Published private(set) var alertLog: [(Date, String)] = []
    private let alertMonitor = AlertMonitor()

    // Speed source — lets speed read past the OBD-II 158 mph ceiling
    enum SpeedSource: String { case obd = "OBD sensor", rpm = "RPM estimate", gps = "GPS" }
    @Published private(set) var speedSource: SpeedSource = .obd
    var speedEstimator = SpeedEstimator()
    @Published var useGPS = false
    @Published var gpsPort = ""
    @Published var gpsBaud = 9600
    @Published private(set) var gpsConnected = false
    @Published private(set) var gpsReading: GPSReceiver.Reading?
    private var gps: GPSReceiver?
    var speedLearnReady: Bool { speedEstimator.ready }

    // Battery test
    @Published private(set) var crankPhase: CrankPhase = .idle
    @Published private(set) var crankSamples: [VoltageSample] = []
    @Published private(set) var crankResult: CrankResult?
    private var crankCancelled = false

    // AI explanation
    @Published private(set) var aiText = ""
    @Published private(set) var aiBusy = false
    @Published private(set) var aiError: String?
    @Published var aiModel: String = UserDefaults.standard.string(forKey: "aiModel") ?? AIExplainer.models[0] {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }

    // Recording
    @Published private(set) var isRecording = false
    private var recordedRows: [String] = []
    private var recordedColumns: [UInt8] = []
    var recordedCount: Int { recordedRows.count }

    private var elm: ELM327?
    private var simTransport: SimulatedTransport?
    private let ioQueue = DispatchQueue(label: "obdreader.serial")
    private var liveTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    var isConnected: Bool { status == .connected }

    /// PIDs to show on the dashboard: the user's picks that the car actually supports.
    var visibleDashboardPIDs: [UInt8] {
        let supported = Set(supportedPIDs)
        return dashboardPIDs.filter { supported.contains($0) && PIDs.def($0) != nil }
    }

    /// Everything the live loop needs: dashboard + trip computer + alerts + menu bar.
    private var livePIDs: [UInt8] {
        var list = visibleDashboardPIDs
        var extra: [UInt8] = [0x0C, 0x0D, 0x10, 0x5E]
        extra += profile?.alerts.filter(\.enabled).map(\.pid) ?? []
        extra += profile?.menuBarPIDs ?? []
        extra += focus.values.flatMap { $0 }
        if trackActive { extra.append(0x11) }
        for p in extra where !list.contains(p) { list.append(p) }
        let supported = Set(supportedPIDs)
        return list.filter { supported.contains($0) && PIDs.def($0) != nil }
    }

    var perfActive: Bool { [PerformanceTimer.Phase.waitingForStop, .ready, .running].contains(perf.phase) }

    // MARK: - Serial work happens off the main thread

    func io<T>(_ work: @escaping @Sendable (ELM327) throws -> T) async throws -> T {
        guard let elm else { throw TransportError.notOpen }
        return try await withCheckedThrowingContinuation { cont in
            ioQueue.async { cont.resume(with: Result { try work(elm) }) }
        }
    }

    private func appendLog(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    // MARK: - Connect

    func refreshPorts() {
        ports = SerialTransport.availablePorts()
        if !ports.contains(selectedPort) { selectedPort = ports.first ?? "" }
    }

    /// Baud rates to try, most common first. ELM327/STN USB adapters vary (OBDLink EX and many
    /// vLinker units run at 115200; a lot of clones default to 38400).
    static let candidateBauds = [115200, 38400, 9600, 57600]

    /// Set by the Stop button while a connection attempt is running.
    private var connectCancelled = false

    /// Abandon a connection attempt (e.g. while it cycles through baud rates). Closing the port
    /// makes the read that's waiting on the adapter return straight away.
    func cancelConnect() {
        guard status == .connecting else { return }
        connectCancelled = true
        busy = "Stopping…"
        elm?.transport.close()
        appendLog("Connection attempt stopped")
    }

    private func finishCancelled() {
        elm = nil
        simTransport = nil
        recorder = nil
        replaying = nil
        busy = nil
        status = .disconnected
    }

    func connect() async {
        guard status != .connecting else { return }
        connectCancelled = false
        status = .connecting
        busy = "Connecting to adapter…"

        replaying = nil
        if useSimulator {
            let sim = SimulatedTransport()
            simTransport = sim
            let rec = recordNextSession ? RecordingTransport(sim) : nil
            let e = makeELM((rec as Transport?) ?? sim)
            elm = e
            appendLog("Opening \(sim.name)")
            do { try await io { try $0.connect() }; recorder = rec; await finishConnect(e) }
            catch { if connectCancelled { finishCancelled() } else { fail(error.localizedDescription) } }
            return
        }

        simTransport = nil
        for baud in Self.candidateBauds {
            if connectCancelled { break }
            busy = "Connecting to adapter… (\(baud) baud)"
            let serial = SerialTransport(path: selectedPort, baud: baud)
            let rec = recordNextSession ? RecordingTransport(serial) : nil
            let transport: Transport = (rec as Transport?) ?? serial
            let e = makeELM(transport)
            elm = e
            appendLog("Opening \(serial.name) at \(baud) baud")
            do {
                try await io { try $0.connect() }
                appendLog("Adapter answered at \(baud) baud")
                recorder = rec
                await finishConnect(e)
                return
            } catch {
                if connectCancelled { break }
                appendLog("No usable reply at \(baud) baud (\(error.localizedDescription))")
                _ = try? await io { $0.disconnect() }
                elm = nil
            }
        }
        if connectCancelled { finishCancelled(); return }
        fail("No response from the adapter at any baud rate. Check it's fully seated in the OBD-II port and the ignition is ON (the adapter is powered by the car, not the USB cable).")
    }

    private func makeELM(_ transport: Transport) -> ELM327 {
        let e = ELM327(transport: transport)
        e.protocolChoice = protocolChoice
        e.listenOnly = listenOnly
        e.log = { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
        return e
    }

    private func finishConnect(_ e: ELM327) async {
        adapterID = e.adapterID
        obdOnUDS = e.obdOnUDS
        connectedListenOnly = e.listenOnly
        protocolName = e.obdProtocol.description + (e.obdOnUDS ? " · OBD on UDS (SAE J1979-2)" : "")
        isCAN = e.obdProtocol.isCAN
        if connectCancelled { finishCancelled(); return }
        battery = try? await io { $0.batteryVoltage() }
        if e.listenOnly {
            // Nothing may be sent to the car, so no sensor discovery and no scan.
            supportedPIDs = []
            responders = []
            status = .connected
            busy = nil
            appendLog("Listen-only connection on \(e.obdProtocol.description): requests to the car are blocked")
            startIdleMonitor()
            return
        }
        busy = "Finding supported sensors…"
        responders = []
        moduleReports = []
        moduleOdometers = [:]
        explorerResults = []
        lastModuleScan = nil
        customValues = [:]; customErrors = [:]; customHistory = [:]
        health.reset()
        try? await discoverPIDs()
        if connectCancelled { finishCancelled(); return }
        status = .connected
        busy = nil
        if recorder != nil { appendLog("Recording this session — disconnect to save it") }
        startIdleMonitor()
        await fullScan()
    }

    /// Open a saved session and run it as if the car were connected.
    func replay(url: URL) async {
        guard status != .connecting, !isConnected else { return }
        do {
            let rec = try Recording.load(url)
            status = .connecting
            busy = "Opening recording…"
            simTransport = nil
            replaying = url.lastPathComponent
            let e = makeELM(ReplayTransport(rec, fileName: url.lastPathComponent))
            e.listenOnly = false            // a recording replays requests; listening isn't recorded
            e.protocolChoice = "0"
            elm = e
            appendLog("Replaying \(url.lastPathComponent) (\(rec.exchanges.count) exchanges, recorded \(rec.created.formatted()))")
            try await io { try $0.connect() }
            await finishConnect(e)
        } catch {
            replaying = nil
            if connectCancelled { finishCancelled(); return }
            fail("Couldn't replay \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func openRecording() {
        let panel = NSOpenPanel()
        panel.directoryURL = Recording.folder
        panel.allowedContentTypes = [UTType(filenameExtension: Recording.fileExtension) ?? .json, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await replay(url: url) }
    }

    func revealRecordings() {
        NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL ?? Recording.folder])
    }

    private func saveRecording() {
        guard let r = recorder else { return }
        recorder = nil
        let rec = r.recording(adapter: adapterID)
        guard !rec.exchanges.isEmpty else { return }
        do {
            let url = try rec.save()
            lastRecordingURL = url
            appendLog("Recording saved: \(url.lastPathComponent) (\(rec.exchanges.count) exchanges)")
        } catch {
            appendLog("Couldn't save the recording: \(error.localizedDescription)")
        }
    }

    // MARK: - Battery-drain watch

    /// While connected but not streaming, check the battery every 20 s. Diagnostic sessions with
    /// the ignition on and the engine off drain a battery quickly — exotic cars especially, with
    /// many modules awake — and a flat battery mid-session is the classic way to cause new faults.
    private func startIdleMonitor() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            var lastWarn = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.isConnected, !Task.isCancelled else { return }
                let crankBusy = [CrankPhase.resting, .waitingForStart, .running].contains(self.crankPhase)
                if self.isLive || self.busy != nil || crankBusy { continue }
                guard let v = try? await self.io({ e -> Double? in
                    e.verbose = false
                    defer { e.verbose = true }
                    return e.batteryVoltage()
                }) else { continue }
                self.battery = v
                if v < 12.0, Date().timeIntervalSince(lastWarn) > 300 {
                    lastWarn = Date()
                    let msg = String(format: "Battery down to %.1f V with the engine off. Connect a battery charger/maintainer or switch the ignition off — a low battery during diagnostics can set false codes.", v)
                    self.alertBanner = msg
                    self.alertLog.insert((Date(), msg), at: 0)
                    self.alertMonitor.announce(msg)
                }
            }
        }
    }

    private func fail(_ msg: String) {
        status = .failed(msg)
        busy = nil
        elm = nil
    }

    func disconnect() async {
        stopLive()
        customLive = false
        trackActive = false
        idleTask?.cancel()
        idleTask = nil
        crankCancelled = true
        stopGPS()
        _ = try? await io { $0.disconnect() }
        saveRecording()
        replaying = nil
        elm = nil
        simTransport = nil
        status = .disconnected
        appendLog("Disconnected")
    }

    // MARK: - GPS (optional speed source)

    func startGPS() {
        stopGPS()
        guard !gpsPort.isEmpty else { appendLog("Pick a GPS port first"); return }
        let r = GPSReceiver()
        if r.open(path: gpsPort, baud: gpsBaud) {
            gps = r
            gpsConnected = true
            appendLog("GPS opened \(gpsPort) @ \(gpsBaud)")
        } else {
            appendLog("GPS failed to open \(gpsPort)")
        }
    }

    func stopGPS() {
        gps?.close()
        gps = nil
        gpsConnected = false
        gpsReading = nil
        if speedSource == .gps { speedSource = .obd }
    }

    private func discoverPIDs() async throws {
        supportedPIDs = await discoverBitmap(service: "01", reply: 0x41)
        if supportedPIDs.isEmpty && isCAN && !obdOnUDS {
            // Maybe an OBD-on-UDS car (SAE J1979-2): the same PIDs, read as service 22 DIDs F4xx.
            _ = try? await io { e in e.obdOnUDS = true }
            let uds = await discoverBitmap(service: "01", reply: 0x41)
            if uds.isEmpty {
                _ = try? await io { e in e.obdOnUDS = false }
            } else {
                supportedPIDs = uds
                obdOnUDS = true
                protocolName += " · OBD on UDS (SAE J1979-2)"
            }
        }
        if obdOnUDS {
            appendLog("This car uses OBD on UDS (SAE J1979-2): live data is read as service 22 DIDs F4xx. Trouble codes: use All Modules.")
        }
    }

    /// Walks the "supported" bitmaps ($00, $20, $40 …) for Mode 01 PIDs or Mode 06 monitor IDs.
    private func discoverBitmap(service: String, reply: UInt8) async -> [UInt8] {
        var found = Set<UInt8>()
        var base: UInt8 = 0x00
        while true {
            let cmd = service + String(format: "%02X", Int(base))
            guard let msgs = try? await io({ try $0.request(cmd) }) else { break }
            for m in msgs {
                if !responders.contains(m.ecu) { responders.append(m.ecu) }
                let f = m.firstFrame
                if f.count >= 6, f[0] == reply, f[1] == base {
                    found.formUnion(PIDs.supported(base: base, bitmap: Array(f[2...5])))
                }
            }
            guard base < 0xE0, found.contains(base &+ 0x20) else { break }
            base &+= 0x20
        }
        return found.filter { $0 % 0x20 != 0 }.sorted()
    }

    // MARK: - Full scan

    func fullScan() async {
        guard isConnected else { return }
        let wasLive = isLive
        stopLive()
        busy = "Reading trouble codes and readiness…"

        readiness = nil
        if let msgs = try? await io({ try $0.request("0101") }) {
            // Merge readiness across every module that answered, not just the engine.
            readiness = Readiness.combined(msgs.map(\.firstFrame))
        }
        driveCycle = nil
        if supportedPIDs.contains(0x41), let msgs = try? await io({ try $0.request("0141") }) {
            driveCycle = Readiness.combined(msgs.map(\.firstFrame), pid: 0x41)
        }

        // Full-scale ranges the car reports for some sensors (PIDs 4F and 50).
        var ranges = SensorRanges()
        if supportedPIDs.contains(0x4F), let msgs = try? await io({ try $0.request("014F") }),
           let f = msgs.map(\.firstFrame).first(where: { $0.count >= 6 && $0[0] == 0x41 && $0[1] == 0x4F }) {
            ranges.maxLambda = f[2] == 0 ? nil : Double(f[2])
            ranges.maxO2Volts = f[3] == 0 ? nil : Double(f[3])
            ranges.maxO2mA = f[4] == 0 ? nil : Double(f[4])
            ranges.maxMAPkPa = f[5] == 0 ? nil : Double(f[5]) * 10
        }
        if supportedPIDs.contains(0x50), let msgs = try? await io({ try $0.request("0150") }),
           let f = msgs.map(\.firstFrame).first(where: { $0.count >= 3 && $0[0] == 0x41 && $0[1] == 0x50 }) {
            ranges.maxMAF = f[2] == 0 ? nil : Double(f[2]) * 10
        }
        sensorRanges = ranges.isEmpty ? nil : ranges

        var codes: [DTC] = []
        for (mode, kind) in [("03", DTCKind.stored), ("07", .pending), ("0A", .permanent)] {
            if let msgs = try? await io({ try $0.request(mode, timeout: 5) }) {
                codes += DTC.parse(msgs, kind: kind)
            }
        }
        dtcs = codes

        busy = "Reading freeze frame…"
        await readFreezeFrame()

        busy = "Reading vehicle information…"
        let vinMsgs = await readInfoMessages("0902")
        var vinMap: [String: String] = [:]
        for (ecu, bytes) in vinMsgs {
            let t = Mode09.text(bytes)
            if !t.isEmpty { vinMap[ecu] = t }
        }
        vins = vinMap
        vin = vinMsgs.map { Mode09.text($0.1) }.first { !$0.isEmpty } ?? ""
        busy = "Reading engine software fingerprint…"
        let calMsgs = await readInfoMessages("0904")
        let cvnMsgs = await readInfoMessages("0906")
        software = calMsgs.map { item in
            SoftwareID(ecu: item.0, calids: Mode09.calids(item.1),
                       cvns: Mode09.cvns(cvnMsgs.first { $0.0 == item.0 }?.1 ?? []))
        }.filter { !$0.calids.isEmpty }
        calibrationIDs = software.flatMap(\.calids)
        ecuNames = (await readInfoMessages("090A")).map { Mode09.text($0.1) }.filter { !$0.isEmpty }
        inUsePerformance = (await readInfoMessages("0908")).first.flatMap { InUsePerformance(payload: $0.1) }
        battery = (try? await io { $0.batteryVoltage() }) ?? battery
        var p = garage.profile(for: vin)
        if p.engineLayout == nil, let guess = EngineLayout.guess(vin: p.vin) {
            p.engineLayout = guess
            garage.update(p)
        }
        if useSimulator, p.vin == SimulatedTransport.vin, p.customPIDs == nil {
            // Demo definition so the Custom Readings page has something to show.
            p.customPIDs = [CustomPID(name: "Oil pressure (demo)", header: "7E0", request: "221001",
                                      formula: "(A*256+B)/1000", unit: "bar")]
            garage.update(p)
        }
        profile = p
        previousScan = garage.history(p.vin).last
        if dashboardPIDs != p.dashboardPIDs { dashboardPIDs = p.dashboardPIDs }

        busy = "Reading the car's self-test results…"
        await readTests()

        busy = "Taking a live snapshot…"
        let snapshot: [UInt8] = [0x03, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0C, 0x1F, 0x21, 0x30, 0x31, 0x42,
                                 0x12, 0x1C, 0x44, 0x4D, 0x4E, 0x51, 0x7F, 0xA4, 0xA6]
        await sampleOnce(Array(Set(livePIDs + snapshot).intersection(Set(supportedPIDs))).sorted())

        refreshVerdicts()
        lastScan = Date()
        saveHistory()
        busy = nil
        if wasLive { startLive() }
    }

    private func refreshVerdicts() {
        var moduleFaults: [(name: String, count: Int)] = []
        let engineAddrs: Set<String> = ["7E0", "7E1", "7E2", "7E3", "7E4", "7E5", "7E6", "7E7"]   // already covered by generic codes
        for m in moduleReports where !m.dtcs.isEmpty && !engineAddrs.contains(m.address) {
            moduleFaults.append((m.name ?? "Module \(m.address)", m.dtcs.count))
        }
        for m in tp20Reports where !m.faults.isEmpty && m.address != 0x01 { moduleFaults.append((m.name, m.faults.count)) }
        findings = Diagnosis.analyze(dtcs: dtcs, readiness: readiness, live: liveValues, battery: battery,
                                     tests: tests, cylinders: profile?.cylinders, moduleFaults: moduleFaults)
        // Fuel type: the Garage setting, or the car's own report (PID 51) if it says diesel.
        let reportsDiesel = PIDs.isDieselFuel(liveValues[0x51]) ?? false
        smog = SmogVerdict.evaluate(readiness: readiness, dtcs: dtcs, modelYear: profile?.modelYear,
                                    isDiesel: (profile?.isDiesel ?? false) || reportsDiesel,
                                    warmUps: liveValues[0x30], kmSinceClear: liveValues[0x31])
        refreshInspection()
    }

    private func refreshInspection() {
        guard isConnected, readiness != nil || !dtcs.isEmpty || !vin.isEmpty else { inspection = nil; return }
        // VINs from the engine computers plus every module that reported one in All Modules.
        var allVins = vins
        for m in moduleReports {
            if let v = m.identification.first(where: { $0.label == "VIN" })?.value, v.count == 17 {
                allVins["Module \(m.name ?? m.address)"] = v
            }
        }
        inspection = PrePurchaseReport.build(.init(
            readiness: readiness, dtcs: dtcs, live: liveValues, vins: allVins, software: software,
            previous: previousScan, dashOdometerKm: dashOdometerKm, tests: tests, battery: battery, units: units,
            moduleOdometers: moduleOdometers))
    }

    private func readTests() async {
        tests = []
        legacyTests = []
        guard isCAN else {
            // Older protocols: Test IDs with a single limit each, manufacturer-defined meanings.
            let tids = await discoverBitmap(service: "06", reply: 0x46)
            var out: [LegacyTestResult] = []
            for tid in tids {
                let cmd = String(format: "06%02X", Int(tid))
                guard let msgs = try? await io({ try $0.request(cmd, timeout: 3) }) else { continue }
                for m in msgs { out += LegacyMode06.parse(m) }
            }
            legacyTests = out
            testsSupported = !out.isEmpty
            return
        }
        let mids = await discoverBitmap(service: "06", reply: 0x46)
        testsSupported = !mids.isEmpty

        // Read from EVERY module that answers, keeping track of which one did. A W16 is run by
        // two engine computers, so reading both is what gives all 16 cylinders' misfire counters.
        var raw: [(ecu: String, result: TestResult)] = []
        for mid in mids {
            let cmd = String(format: "06%02X", Int(mid))
            guard let msgs = try? await io({ try $0.request(cmd, timeout: 2) }) else { continue }
            for m in msgs {
                for r in Mode06.parse(m.firstFrame) { raw.append((m.ecu, r)) }
            }
        }
        // The engine computers are the ones reporting per-cylinder misfire monitors. Order them
        // by their CAN header and give the second one a +8 cylinder offset (its cyl 1 → cyl 9).
        // Offsets are data-driven: each computer starts after the highest cylinder the previous
        // one reported (8 on a W16, 6 on a two-computer V12). If the Garage knows the cylinder
        // count, a computer that reports more slots than its share is capped to its share.
        let engineECUs = Set(raw.filter { $0.result.cylinder != nil }.map { $0.ecu }).sorted()
        var offset: [String: Int] = [:]
        var next = 0
        for e in engineECUs {
            offset[e] = next
            var count = raw.filter { $0.ecu == e }.compactMap { $0.result.cylinder }.max() ?? 0
            if let n = profile?.cylinders, engineECUs.count > 1 { count = min(count, n / engineECUs.count) }
            next += count
        }
        tests = raw.map { item in
            var r = item.result
            r.ecu = item.ecu
            r.bankOffset = offset[item.ecu] ?? 0
            return r
        }
    }

    private func readFreezeFrame() async {
        freezeFrame = []
        freezeFrameDTC = nil
        guard let msgs = try? await io({ try $0.request("020200") }),
              let f = ELM327.enginePreferred(msgs).first?.firstFrame, f.count >= 5, f[0] == 0x42,
              let code = DTC.decode(f[3], f[4]) else { return }
        freezeFrameDTC = code
        let wanted: [UInt8] = [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11]
        var rows: [(PIDDef, Double)] = []
        for pid in wanted where supportedPIDs.contains(pid) {
            guard let def = PIDs.def(pid) else { continue }
            let cmd = String(format: "02%02X00", Int(pid))
            if let msgs = try? await io({ try $0.request(cmd) }),
               let f = ELM327.enginePreferred(msgs).first?.firstFrame,
               f.count >= 3 + def.bytes, f[0] == 0x42, f[1] == pid {
                rows.append((def, def.decode(Array(f[3...]))))
            }
        }
        freezeFrame = rows
    }

    /// Mode 09 items as (ECU, data bytes), engine computer first.
    private func readInfoMessages(_ cmd: String) async -> [(String, [UInt8])] {
        guard let msgs = try? await io({ try $0.request(cmd, timeout: 4) }) else { return [] }
        return ELM327.enginePreferred(msgs).map { ($0.ecu, Mode09.payload($0)) }.filter { !$0.1.isEmpty }
    }

    /// Misfires counted last drive across all named cylinders (Mode 06), if reported.
    private var misfireTotal: Int? {
        let rows = tests.filter { $0.cylinder != nil && $0.tid == 0x0C }
        return rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.raw }
    }

    private func saveHistory() {
        guard let p = profile else { return }
        let record = ScanRecord(
            date: Date(),
            codes: dtcs.map { SavedCode(code: $0.code, kind: $0.kind.rawValue, ecu: $0.ecu) },
            milOn: readiness?.milOn,
            incompleteMonitors: readiness?.monitors.filter { !$0.complete }.map(\.name) ?? [],
            snapshot: liveValues,
            battery: battery,
            failedTests: tests.filter { !$0.passed }.map { "\($0.monitorName): \($0.testName)" },
            nearLimitTests: tests.filter(\.nearLimit).map { "\($0.monitorName): \($0.testName)" },
            smogVerdict: smog?.result.rawValue,
            software: software.isEmpty ? nil : software,
            vins: vins.isEmpty ? nil : vins,
            odometerKm: liveValues[0xA6],
            misfireTotal: misfireTotal,
            worstMargin: tests.compactMap(\.margin).min(),
            idleWobble: health.idleWobble)
        garage.append(record, vin: p.vin)
    }

    // MARK: - Garage

    func saveProfile(_ p: CarProfile) {
        garage.update(p)
        if p.vin == profile?.vin {
            profile = p
            if dashboardPIDs != p.dashboardPIDs { dashboardPIDs = p.dashboardPIDs }
            if lastScan != nil { refreshVerdicts() }
        }
    }

    // MARK: - Live data

    private func sampleOnce(_ pids: [UInt8]) async {
        guard !pids.isEmpty,
              let raw = try? await io({ elm -> [UInt8: [UInt8]] in
                  elm.verbose = false
                  defer { elm.verbose = true }
                  return elm.readPIDs(pids)
              }) else { return }

        var values: [UInt8: Double] = [:]
        var ext: [String: Double] = [:]
        for (pid, bytes) in raw {
            guard let def = PIDs.def(pid), bytes.count >= def.bytes else { continue }
            let v = def.decode(bytes)
            if v.isFinite { values[pid] = v }
            for ch in def.channels {
                if let x = ch.decode(bytes), x.isFinite { ext[ch.key] = x }
            }
        }

        // Speed source: learn the RPM↔speed ratio while OBD speed is trustworthy, then prefer GPS,
        // then an RPM estimate once the OBD value saturates at 255 km/h (158 mph), then OBD as given.
        let rpmNow = values[0x0C] ?? liveValues[0x0C]
        if let rpm = rpmNow, let sp = values[0x0D], sp < 254 { speedEstimator.learn(rpm: rpm, obdSpeedKmh: sp) }
        if let r = gps?.reading, r.age < 2 {
            gpsReading = r
            values[0x0D] = r.kmh
            speedSource = .gps
        } else if let sp = values[0x0D] {
            if sp >= 254, let rpm = rpmNow, let est = speedEstimator.estimate(rpm: rpm), est > sp {
                values[0x0D] = est
                speedSource = .rpm
            } else {
                speedSource = .obd
            }
        }

        let now = Date()
        sampleTimes.append(now)
        sampleTimes.removeAll { now.timeIntervalSince($0) > 3 }
        samplesPerSecond = Double(sampleTimes.count) / 3

        for (pid, v) in values {
            liveValues[pid] = v
            var h = history[pid] ?? []
            h.append(v)
            if h.count > 120 { h.removeFirst(h.count - 120) }
            history[pid] = h
        }
        health.feed(liveValues, at: now)
        for (k, v) in ext {
            extValues[k] = v
            var h = extHistory[k] ?? []
            h.append(v)
            if h.count > 120 { h.removeFirst(h.count - 120) }
            extHistory[k] = h
        }

        guard isLive else { return }

        if trackActive {
            let fix = gps?.reading.flatMap { $0.age < 2 ? $0 : nil }
            if let kmh = fix?.kmh ?? values[0x0D] {
                track.update(t: fix?.fixTime ?? now, kmh: kmh, lat: fix?.lat, lon: fix?.lon, course: fix?.course,
                             rpm: liveValues[0x0C], throttle: liveValues[0x11])
            }
        }

        trip.update(speed: values[0x0D], fuelRate: liveValues[0x5E], maf: liveValues[0x10],
                    rpm: liveValues[0x0C], at: now)

        if perfActive, let v = values[0x0D], let run = perf.update(speed: v, at: now) {
            perfRuns.insert(run, at: 0)
        }

        let fired = alertMonitor.check(values, rules: profile?.alerts ?? AlertRule.defaults, units: units)
        if !fired.isEmpty {
            alertBanner = fired.joined(separator: "\n")
            for f in fired { alertLog.insert((now, f), at: 0) }
            if alertLog.count > 200 { alertLog.removeLast(alertLog.count - 200) }
        }

        if isRecording {
            let ts = ISO8601DateFormatter().string(from: now)
            let cols = recordedColumns.map { pid -> String in
                values[pid].map { String(format: "%.3f", $0) } ?? ""
            }
            recordedRows.append(([ts] + cols).joined(separator: ","))
        }
    }

    func startLive() {
        guard isConnected, !isLive, busy == nil else { return }
        isLive = true
        liveTask = Task { [weak self] in
            var lastBattery = Date.distantPast
            while let self, self.isLive, !Task.isCancelled {
                // During a performance run poll only speed, as fast as the car answers.
                let pids: [UInt8] = self.perfActive ? [0x0D] : self.livePIDs
                await self.sampleOnce(pids)
                if self.customLive, !self.perfActive, Date().timeIntervalSince(self.lastCustomRead) > 1 {
                    await self.readCustomValues()
                }
                if !self.perfActive {
                    if Date().timeIntervalSince(lastBattery) > 2,
                       let v = try? await self.io({ e -> Double? in
                           e.verbose = false
                           defer { e.verbose = true }
                           return e.batteryVoltage()
                       }) {
                        self.battery = v
                        lastBattery = Date()
                    }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
            }
        }
    }

    func stopLive() {
        isLive = false
        liveTask?.cancel()
        liveTask = nil
    }

    func dismissAlert() { alertBanner = nil }

    // MARK: - Trip & performance

    func resetTrip() { trip.reset() }

    func armPerformance() {
        perf.arm(metric: units == .metric)
        if !isLive { startLive() }
    }

    func cancelPerformance() { perf.cancel() }

    // MARK: - Track day

    var gpsPosition: (lat: Double, lon: Double)? {
        guard let r = gps?.reading, r.age < 2, let la = r.lat, let lo = r.lon else { return nil }
        return (la, lo)
    }

    func setStartLineHere() {
        guard let p = gpsPosition else { appendLog("No GPS position yet — start the GPS on the Connection page"); return }
        track.startLine = p
        appendLog(String(format: "Start/finish set at %.6f, %.6f", p.lat, p.lon))
    }

    func startTrack() {
        track.reset()
        trackActive = true
        if !isLive { startLive() }
    }

    func stopTrack() { trackActive = false }
    func resetTrack() { track.reset() }
    func trackCSV() -> String { track.csv(metric: units == .metric) }

    // MARK: - Battery / cranking test

    func runCrankTest() async {
        guard isConnected, crankPhase != .resting, crankPhase != .waitingForStart, crankPhase != .running else { return }
        stopLive()
        crankCancelled = false
        crankSamples = []
        crankResult = nil
        crankPhase = .resting
        simTransport?.beginCrankScenario()

        let t0 = Date()
        var rest: [Double] = []
        var crankTime: Double?
        var misses = 0

        while !crankCancelled {
            let v = try? await io({ e -> Double? in
                e.verbose = false
                defer { e.verbose = true }
                return e.batteryVoltage()
            })
            let t = Date().timeIntervalSince(t0)
            guard let v else {
                misses += 1
                if misses > 60 {
                    crankPhase = .failed("Lost contact with the adapter. The voltage may have dropped too low for it during cranking — that alone suggests a weak battery.")
                    return
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            crankSamples.append(VoltageSample(t: t, volts: v))

            switch crankPhase {
            case .resting:
                rest.append(v)
                if t >= 2 { crankPhase = .waitingForStart }
            case .waitingForStart:
                let restV = rest.reduce(0, +) / Double(max(rest.count, 1))
                if v < restV - 0.6 {
                    crankTime = t
                    crankPhase = .running
                } else if t > 32 {
                    crankPhase = .failed("No engine start was detected within 30 seconds.")
                    return
                }
            case .running:
                if let ct = crankTime, t - ct > 7 {
                    let restV = rest.reduce(0, +) / Double(max(rest.count, 1))
                    let crankWindow = crankSamples.filter { $0.t >= ct - 0.3 && $0.t <= ct + 3 }
                    let tail = crankSamples.filter { $0.t >= t - 1.5 }
                    let runV = tail.map(\.volts).reduce(0, +) / Double(max(tail.count, 1))
                    crankResult = CrankResult(rest: restV,
                                              crankMin: crankWindow.map(\.volts).min() ?? v,
                                              running: runV > restV + 0.3 ? runV : nil)
                    crankPhase = .done
                    return
                }
            default:
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        crankPhase = .idle
    }

    func cancelCrankTest() { crankCancelled = true }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording { isRecording = false; return }
        recordedRows = []
        recordedColumns = livePIDs
        isRecording = true
        if !isLive { startLive() }
    }

    func recordingCSV() -> String {
        let header = (["timestamp"] + recordedColumns.map { pid -> String in
            "\(PIDs.def(pid)?.name ?? String(format: "PID %02X", Int(pid))) (metric)"
        }).joined(separator: ",")
        return ([header] + recordedRows).joined(separator: "\n") + "\n"
    }

    // MARK: - Clear codes (Mode 04)

    func clearCodes() async {
        guard isConnected else { return }
        stopLive()
        busy = "Clearing codes…"
        do {
            _ = try await io { try $0.request("04", timeout: 6) }
            appendLog("Codes cleared")
        } catch {
            appendLog("Clear failed: \(error.localizedDescription)")
        }
        busy = nil
        await fullScan()
    }

    // MARK: - AI explanation

    func explainWithAI(includeVIN: Bool) async {
        let key = Keychain.load()
        guard !key.isEmpty else { aiError = "Add your Anthropic API key first."; return }
        aiBusy = true
        aiError = nil
        defer { aiBusy = false }
        do {
            aiText = try await AIExplainer.explain(report: report(includeVIN: includeVIN), apiKey: key, model: aiModel)
        } catch {
            aiError = error.localizedDescription
        }
    }

    // MARK: - Reports

    func exportPDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile?.nickname ?? "OBD") report.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try PDFExporter.write(markdown: report(), to: url) }
        catch { appendLog("PDF export failed: \(error.localizedDescription)") }
    }

    func report(includeVIN: Bool = true) -> String {
        var r = "# OBD Reader diagnostic report\n\n"
        r += "Date: \(Date().formatted(date: .long, time: .shortened))\n\n"
        r += "## Vehicle\n\n"
        if let p = profile { r += "- Car: \(p.nickname)\(p.modelYear.map { " (\($0))" } ?? "")\n" }
        if includeVIN { r += "- VIN: \(vin.isEmpty ? "not reported" : vin)\n" }
        if let m = VINDecoder.manufacturer(vin) { r += "- Make (from VIN): \(m)\n" }
        for sw in software {
            r += "- Software, ECU \(sw.ecu): \(sw.calids.joined(separator: ", "))"
            r += sw.cvns.isEmpty ? "\n" : " (CVN \(sw.cvns.joined(separator: ", ")))\n"
        }
        if let ft = PIDs.fuelTypeText(liveValues[0x51]) { r += "- Fuel type (reported): \(ft)\n" }
        if let p = profile, let layout = p.engineLayout { r += "- Engine: \(layout)\n" }
        if !ecuNames.isEmpty { r += "- ECU names: \(ecuNames.joined(separator: ", "))\n" }
        r += "- Protocol: \(protocolName)\n- Adapter: \(adapterID)\n"
        if let b = battery { r += String(format: "- Battery: %.1f V\n", b) }

        r += "\n## Findings\n\n"
        for f in findings {
            r += "- **[\(f.severity.label)] \(f.title)** — \(f.detail)\n"
            for c in f.checks { r += "    - \(c)\n" }
        }

        r += "\n## Trouble codes\n\n"
        if dtcs.isEmpty { r += "None reported.\n" }
        for d in dtcs {
            r += "- \(d.code) (\(d.kind.rawValue), ECU \(d.ecu)): \(d.description)\n"
            if let c = d.causes { r += "    - Common causes: \(c)\n" }
        }

        if let code = freezeFrameDTC {
            r += "\n## Freeze frame (set by \(code))\n\n"
            for (def, v) in freezeFrame { r += "- \(def.name): \(def.format(v, units))\n" }
        }

        if let rd = readiness {
            r += "\n## Readiness\n\n- Check-engine light: \(rd.milOn ? "ON" : "off")\n"
            for m in rd.monitors { r += "- \(m.name): \(m.complete ? "complete" : "NOT complete")\n" }
        }

        if let ins = inspection {
            r += "\n## Pre-purchase check\n\n- Verdict: **\(ins.verdict)**\n"
            for f in ins.flags where f.level != .ok { r += "- [\(f.level.label)] \(f.title) — \(f.detail)\n" }
            for f in ins.flags where f.level == .ok { r += "- [OK] \(f.title)\n" }
        }

        if let s = smog {
            r += "\n## California smog check (OBD portion, estimate)\n\n- Result: **\(s.result.rawValue)**\n"
            for x in s.reasons { r += "- \(x)\n" }
            for x in s.notes { r += "    - \(x)\n" }
        }

        if !tests.isEmpty {
            r += "\n## On-board self-test results\n\n"
            for t in tests where !t.isMisfireCounter {
                let sc = t.scaled
                let flag = !t.passed ? " — **FAILED**" : (t.nearLimit ? " — close to limit" : "")
                r += "- \(t.monitorName), \(t.testName): \(t.formatted(sc.value))"
                if t.hasLimits { r += " (limits \(t.formatted(sc.min)) – \(t.formatted(sc.max)))" }
                r += "\(flag)\n"
            }
            let mis = tests.filter { $0.cylinder != nil && $0.tid == 0x0C }
            if !mis.isEmpty {
                r += "- Misfires last drive by cylinder: " + mis.map { "\($0.cylinder!): \($0.raw)" }.joined(separator: ", ") + "\n"
            }
        }

        if let c = crankResult {
            r += "\n## Battery test\n\n"
            r += String(format: "- Resting: %.2f V — %@\n", c.rest, c.restVerdict)
            r += String(format: "- Lowest while cranking: %.2f V — %@\n", c.crankMin, c.crankVerdict)
            r += "- Running: \(c.running.map { String(format: "%.2f V", $0) } ?? "—") — \(c.runningVerdict)\n"
        }

        if let p = profile {
            let past = garage.history(p.vin).dropLast().suffix(5)
            if !past.isEmpty {
                r += "\n## Previous scans\n\n"
                for h in past.reversed() {
                    let codes = h.codes.map(\.code)
                    r += "- \(h.date.formatted(date: .abbreviated, time: .omitted)): \(codes.isEmpty ? "no codes" : codes.joined(separator: ", "))\n"
                }
            }
        }

        r += moduleScanReport()
        r += tp20ReportText()
        r += importedLogsReport()

        r += "\n## Live snapshot\n\n"
        for pid in liveValues.keys.sorted() {
            guard let def = PIDs.def(pid), let v = liveValues[pid] else { continue }
            switch pid {
            case 0x03: r += "- \(def.name): \(PIDs.fuelSystemText(v))\n"
            case 0x51: r += "- \(def.name): \(PIDs.fuelTypeText(v) ?? "code \(Int(v))")\n"
            case 0x1C: r += "- \(def.name): \(PIDs.obdStandardText(v) ?? "")\n"
            case 0x12: r += "- \(def.name): \(PIDs.secondaryAirText(v) ?? "code \(Int(v))")\n"
            case 0x1E, 0xA9: r += "- \(def.name): \(v >= 1 ? "yes" : "no")\n"
            default:
                if def.channels.isEmpty { r += "- \(def.name): \(def.format(v, units))\n" }
            }
        }
        for item in PIDs.channels {
            if let v = extValues[item.channel.key] { r += "- \(item.channel.name): \(item.channel.kind.format(v, units))\n" }
        }
        return r
    }

    /// For dashboard PIDs that carry a second reading (O2 sensors): "short-term trim −3.1 %".
    func channelSummary(_ def: PIDDef) -> String? {
        guard def.onDashboard, def.channels.count > 1 else { return nil }
        let parts = def.channels.dropFirst().compactMap { ch -> String? in
            guard let v = extValues[ch.key] else { return nil }
            return ch.name + ": " + ch.kind.format(v, units)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Custom readings

    var customPIDs: [CustomPID] { profile?.customPIDs ?? [] }

    private func setCustomPIDs(_ list: [CustomPID]) {
        guard var p = profile else { return }
        p.customPIDs = list
        saveProfile(p)
    }

    func upsertCustomPID(_ pid: CustomPID) {
        var list = customPIDs
        if let i = list.firstIndex(where: { $0.id == pid.id }) { list[i] = pid } else { list.append(pid) }
        setCustomPIDs(list)
    }

    func deleteCustomPID(_ id: UUID) {
        setCustomPIDs(customPIDs.filter { $0.id != id })
        customValues[id] = nil; customErrors[id] = nil; customHistory[id] = nil
    }

    func toggleCustomLive() {
        customLive.toggle()
        if customLive && !isLive { startLive() }
    }

    func readCustomOnce() async {
        guard isConnected, busy == nil else { return }
        let wasLive = isLive
        stopLive()
        busy = "Reading custom values…"
        await readCustomValues()
        busy = nil
        if wasLive { startLive() }
    }

    private func readCustomValues() async {
        lastCustomRead = Date()
        var cache: [String: Result<[ECUMessage], CustomPIDError>] = [:]     // one request per module+identifier per pass
        for pid in customPIDs where pid.enabled && pid.problem == nil {
            let header = pid.cleanHeader, req = pid.cleanRequest
            let result: Result<[UInt8], CustomPIDError>
            do {
                let key = header + "|" + req
                let fetched: Result<[ECUMessage], CustomPIDError>
                if let c = cache[key] { fetched = c } else {
                    do {
                        let m = try await io { e -> [ECUMessage] in
                            e.verbose = false
                            defer { e.verbose = true }
                            return try e.requestTo(header: header, req)
                        }
                        fetched = .success(m)
                    } catch CustomPIDError.message(let m) {
                        fetched = .failure(.message(m))
                    } catch {
                        fetched = .failure(.message(error.localizedDescription))
                    }
                    cache[key] = fetched
                }
                let msgs = try fetched.get()
                result = pid.extract(msgs)
            } catch CustomPIDError.message(let m) {
                result = .failure(.message(m))
            } catch {
                result = .failure(.message(error.localizedDescription))
            }
            switch result {
            case .success(let bytes):
                do {
                    let v = try pid.compute(bytes)
                    customValues[pid.id] = v
                    customErrors[pid.id] = nil
                    var h = customHistory[pid.id] ?? []
                    h.append(v)
                    if h.count > 120 { h.removeFirst(h.count - 120) }
                    customHistory[pid.id] = h
                } catch Formula.FormulaError.bad(let m) {
                    customErrors[pid.id] = "Formula: \(m)"
                } catch {
                    customErrors[pid.id] = "Formula error"
                }
            case .failure(.message(let m)):
                customErrors[pid.id] = m
            }
        }
    }

    func importCustomPIDs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: CustomPIDFiles.fileExtension) ?? .json, .json,
                                     .commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var list = customPIDs
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let loaded = OBDb.isSignalset(data)
                ? OBDb.load(data, source: "OBDb · \(url.deletingPathExtension().lastPathComponent) (CC BY-SA 4.0)", modelYear: profile?.modelYear)
                : CustomPIDFiles.load(data)
            appendLog("Imported \(loaded.count) custom reading\(loaded.count == 1 ? "" : "s") from \(url.lastPathComponent)")
            for p in loaded where !list.contains(where: { $0.cleanHeader == p.cleanHeader && $0.cleanRequest == p.cleanRequest && $0.formula == p.formula && $0.name == p.name }) {
                list.append(p)
            }
        }
        setCustomPIDs(list)
    }

    @Published private(set) var obdbStatus: String?

    func setCustomEnabled(_ ids: Set<UUID>, _ on: Bool) {
        setCustomPIDs(customPIDs.map { p in var q = p; if ids.contains(p.id) { q.enabled = on }; return q })
    }

    /// Download this model's signalset from OBDb and add its readings (disabled until chosen).
    func fetchOBDb() async {
        guard let mk = profile?.make, let md = profile?.model, !mk.isEmpty, !md.isEmpty else { return }
        let vinAtStart = profile?.vin
        let repo = OBDb.repoName(make: mk, model: md)
        guard let url = OBDb.url(repo: repo) else { return }
        obdbStatus = "Downloading \(repo) from OBDb…"
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                obdbStatus = h.statusCode == 404
                    ? "OBDb has no \(repo) yet. Check the make/model spelling in the Garage, or browse github.com/OBDb."
                    : "OBDb download failed (HTTP \(h.statusCode))."
                return
            }
            guard profile?.vin == vinAtStart else { obdbStatus = nil; return }    // car changed meanwhile
            let loaded = OBDb.load(data, source: "OBDb · \(repo) (CC BY-SA 4.0)", modelYear: profile?.modelYear,
                                   is29Bit: isConnected ? protocolName.contains("29-bit") : nil)
            var list = customPIDs
            var added = 0
            for p in loaded where !list.contains(where: { $0.cleanHeader == p.cleanHeader && $0.cleanRequest == p.cleanRequest && $0.formula == p.formula && $0.name == p.name }) {
                list.append(p); added += 1
            }
            setCustomPIDs(list)
            obdbStatus = "Added \(added) reading\(added == 1 ? "" : "s") from OBDb \(repo)\(profile?.modelYear.map { " (filtered for \($0))" } ?? ""). They start switched off — enable the ones you want."
            appendLog("OBDb: \(added) readings from \(repo)")
        } catch {
            obdbStatus = "OBDb download failed: \(error.localizedDescription)"
        }
    }

    func exportCustomPIDs(csv: Bool) {
        let panel = NSSavePanel()
        let base = (profile?.nickname ?? "Custom readings")
        if csv {
            panel.nameFieldStringValue = "\(base).csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        } else {
            panel.nameFieldStringValue = "\(base).\(CustomPIDFiles.fileExtension)"
            panel.allowedContentTypes = [UTType(filenameExtension: CustomPIDFiles.fileExtension) ?? .json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = csv ? Data(CustomPIDFiles.exportCSV(customPIDs).utf8) : (CustomPIDFiles.exportJSON(customPIDs) ?? Data())
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - All-module fault codes

    /// Brand list chosen for this car (or guessed from its make).
    var modulePreset: ModulePreset? {
        if let b = profile?.modulePreset { return ModulePreset.named(b) }   // "none" = chosen off
        return ModulePreset.guess(make: profile?.make)
    }

    func setModulePreset(_ brand: String?) {
        guard var p = profile else { return }
        p.modulePreset = brand
        saveProfile(p)
    }

    /// Every address on the list, before dropping ones the car's CAN type can't reach.
    private var allModuleSpecs: [String] {
        var list: [String] = []
        let is29 = protocolName.contains("29-bit")
        for r in responders {
            if let a = UDS.requestAddress(forResponder: r, is29Bit: is29) { list.append(a) }
        }
        if !is29 {
            for v in 0x7E0...0x7E7 { list.append(String(format: "%03X", v)) }
        }
        list += (modulePreset?.entries ?? []).map(\.spec)
        list += (libraryMatch?.modules ?? []).map(\.spec)
        list += (profile?.extraModuleAddresses ?? []).compactMap { ModuleTarget(spec: $0)?.spec }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// Addresses the scan will try: responders, 7E0–7E7 on 11-bit CAN, the brand list and the car's extras.
    var moduleAddresses: [String] {
        let is29 = protocolName.contains("29-bit")
        return allModuleSpecs.filter { ModuleTarget(spec: $0)?.is29Bit == is29 }
    }

    /// Brand-list addresses skipped because they use the other CAN ID length.
    var skippedModuleAddresses: [String] {
        let is29 = protocolName.contains("29-bit")
        return allModuleSpecs.filter { ModuleTarget(spec: $0)?.is29Bit != is29 }
    }

    func moduleName(_ spec: String) -> String? {
        ModulePreset.label(for: spec, in: modulePreset)
            ?? libraryMatch?.modules.first(where: { $0.spec == spec })?.name
    }

    /// Our own library's entry for this car (same make/model, or same VIN maker/model code).
    var libraryMatch: LibraryModel? {
        ModuleLibrary.shared.match(make: profile?.make, model: profile?.model, vin: vin)
    }

    // MARK: - Address sweep

    @Published private(set) var sweepHits: [SweepHit] = []
    @Published private(set) var sweepProgress: Double?
    @Published private(set) var lastSweep: Date?
    private var sweepStopRequested = false
    var sweepRunning: Bool { sweepProgress != nil }

    func stopSweep() {
        guard sweepRunning else { return }
        sweepStopRequested = true
        busy = "Stopping sweep…"
    }

    /// Ask every diagnostic address for its identification (22 F190, read-only) and record who answers.
    func sweepModules() async {
        guard isConnected, isCAN, busy == nil else { return }
        let wasLive = isLive
        stopLive()
        let is29 = protocolName.contains("29-bit")
        let targets: [String] = is29
            ? (0x00...0xFE).filter { $0 != 0xF1 }.map { String(format: "18DA%02XF1", $0) }
            : (0x700...0x7FF).filter { $0 != 0x7DF && !(0x7E8...0x7EF).contains($0) }.map { String(format: "%03X", $0) }
        sweepHits = []
        sweepStopRequested = false
        sweepProgress = 0
        busy = "Sweeping module addresses…"
        appendLog("Address sweep started: \(targets.count) addresses")
        do { try await io { try $0.beginSweep() } } catch { appendLog("Sweep setup: \(error.localizedDescription)") }
        var skip = Set<String>()     // reply IDs already seen: never transmit on a module's own ID
        for (i, addr) in targets.enumerated() {
            if sweepStopRequested { break }
            sweepProgress = Double(i) / Double(targets.count)
            if skip.contains(addr) { continue }
            busy = "Sweeping \(addr) (\(i + 1)/\(targets.count))…"
            guard let found = (try? await io({ $0.probe(addr) })) ?? nil else { continue }
            var hit = found
            skip.insert(hit.reply)
            hit.systemName = (try? await io({ $0.systemName(addr) })) ?? nil
            sweepHits.append(hit)
            appendLog("Sweep: \(hit.spec) answered\(hit.systemName.map { " (\($0))" } ?? "")")
        }
        _ = try? await io { $0.endSweep() }
        appendLog("Address sweep \(sweepStopRequested ? "stopped" : "finished"): \(sweepHits.count) module\(sweepHits.count == 1 ? "" : "s")")
        sweepProgress = nil
        lastSweep = Date()
        busy = nil
        if wasLive { startLive() }
    }

    @Published private(set) var autoScanning = false

    /// Our own Auto-Scan: sweep for modules, scan every known module for codes and IDs,
    /// and save what was found to the module library. All read-only.
    func autoScan() async {
        guard isConnected, isCAN, busy == nil else { return }
        autoScanning = true
        defer { autoScanning = false }
        await sweepModules()
        guard !sweepStopRequested else { return }
        if !sweepHits.isEmpty { saveSweepToLibrary() }
        await scanModules(readIDs: true)
        if moduleReports.contains(where: \.answered) { saveScanToLibrary() }
        if modulePreset?.brand.hasPrefix("VW") == true && !protocolName.contains("29-bit") {
            await scanTP20()
        }
    }

    /// Plain-text Auto-Scan report, like a workshop scan printout.
    func autoScanReportText() -> String {
        var r = "OBD Reader Auto-Scan\n"
        r += "Date: \(Date().formatted(date: .long, time: .shortened))\n"
        if let p = profile {
            r += "Car: \([p.modelYear.map { String($0) }, p.make, p.model].compactMap { $0 }.joined(separator: " "))\n"
        }
        if !vin.isEmpty { r += "VIN: \(vin)\n" }
        r += "Connection: \(protocolName)\n"
        if let t = lastSweep { r += "Address sweep: \(t.formatted(date: .omitted, time: .shortened)), \(sweepHits.count) module(s) answered\n" }
        let answered = moduleReports.filter(\.answered)
        r += "Modules answered: \(answered.count) · with codes: \(answered.filter { !$0.dtcs.isEmpty }.count)\n"
        r += moduleScanReport()
        r += tp20ReportText()
        let silent = moduleReports.filter { !$0.answered }.map(\.address)
        if !silent.isEmpty { r += "\nNo reply from: \(silent.joined(separator: ", "))\n" }
        return r
    }

    func exportAutoScanReport() {
        let panel = NSSavePanel()
        let base = (profile?.nickname ?? "Car").replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "Auto-Scan \(base) \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(autoScanReportText().utf8).write(to: url, options: .atomic)
    }

    // MARK: - VW TP2.0 (older VW-group modules)

    @Published private(set) var tp20Reports: [TP20Report] = []
    @Published private(set) var tp20Progress: Double?
    @Published private(set) var lastTP20Scan: Date?
    private var tp20StopRequested = false
    var tp20Running: Bool { tp20Progress != nil }

    func stopTP20() {
        guard tp20Running else { return }
        tp20StopRequested = true
        busy = "Stopping TP2.0 scan…"
    }

    func scanTP20() async {
        guard isConnected, isCAN, !protocolName.contains("29-bit"), busy == nil else { return }
        let wasLive = isLive
        stopLive()
        tp20Reports = []
        tp20StopRequested = false
        tp20Progress = 0
        busy = "Scanning VW TP2.0 modules…"
        appendLog("TP2.0 scan started")
        do { try await io { try $0.tp20Begin() } } catch { appendLog("TP2.0 setup: \(error.localizedDescription)") }
        let list = TP20.sweepAddresses
        for (i, a) in list.enumerated() {
            if tp20StopRequested { break }
            tp20Progress = Double(i) / Double(list.count)
            busy = String(format: "TP2.0 address %02X (%d/%d)…", Int(a), i + 1, list.count)
            if let rep = (try? await io({ $0.tp20Read(a) })) ?? nil {
                tp20Reports.append(rep)
                appendLog(String(format: "TP2.0: %02X %@ answered, %d fault(s)", Int(a), rep.name, rep.faults.count))
            }
        }
        _ = try? await io { $0.tp20End() }
        appendLog("TP2.0 scan \(tp20StopRequested ? "stopped" : "finished"): \(tp20Reports.count) module(s)")
        refreshVerdicts()
        tp20Progress = nil
        lastTP20Scan = Date()
        busy = nil
        if wasLive { startLive() }
    }

    // MARK: - CAN bus listener (DBC files) — listen only, nothing is sent to the car

    @Published private(set) var busListening = false
    @Published private(set) var busStatus: String?
    @Published private(set) var busStats: [CANKey: BusStat] = [:]
    @Published private(set) var busFrames = 0
    @Published private(set) var busOverflows = 0
    @Published private(set) var busSeconds = 0.0            // time spent listening (for rates)
    @Published private(set) var busRanges: [String: (Double, Double)] = [:]   // "1A0.Signal" → min, max
    @Published private(set) var busSource: String?          // "Live" or the log file's name
    /// The DBC used to decode (and to track min/max while listening).
    @Published var busDBC: DBCFile? { didSet { busRanges = [:] } }
    private(set) var busLog: [BusLogEntry] = []
    private var busStop = false
    private static let busLogCap = 500_000

    func clearBus() {
        guard !busListening else { return }
        busStats = [:]; busFrames = 0; busOverflows = 0; busSeconds = 0
        busRanges = [:]; busLog = []; busStatus = nil; busSource = nil
    }

    func stopBusListen() {
        busStop = true
        busy = "Stopping…"
    }

    /// Listen in half-second windows until Stop. `only`: one ID (the adapter filters the rest,
    /// which helps slow adapters keep up).
    func startBusListen(only: CANKey?) async {
        guard isConnected, isCAN, busy == nil else { return }
        let wasLive = isLive
        stopLive()
        if busSource != "Live" { clearBus() }
        busSource = "Live"
        busStop = false
        busStatus = nil
        busListening = true
        busy = "Listening to the CAN bus…"
        appendLog("CAN listener started" + (only.map { " (only \($0.text))" } ?? ""))
        let filter = only?.text
        do {
            try await io { try $0.listenBegin(filter: filter) }
            var quiet = 0
            while !busStop {
                let started = Date()
                let r = try await io { try $0.listenWindow(seconds: 0.5) }
                let span = Date().timeIntervalSince(started)
                let base = busSeconds
                busSeconds += span
                if r.overflow { busOverflows += 1 }
                ingestBus(r.frames.enumerated().map { i, f in
                    BusLogEntry(t: base + span * Double(i) / Double(max(1, r.frames.count)), frame: f)
                })
                quiet = r.frames.isEmpty ? quiet + 1 : 0
                if busFrames == 0 && quiet >= 6 {
                    busStatus = "Nothing heard yet. Many cars keep their internal traffic off the OBD port (a gateway passes only diagnostic requests), so there may be nothing to hear here. Still listening."
                } else if busFrames > 0 && busStatus?.hasPrefix("Nothing heard") == true {
                    busStatus = nil
                }
            }
        } catch {
            busStatus = "Listening stopped: \(error.localizedDescription)"
        }
        _ = try? await io { $0.listenEnd() }
        appendLog("CAN listener stopped: \(busFrames) frames, \(busStats.count) IDs" + (busOverflows > 0 ? ", adapter buffer overflowed \(busOverflows)×" : ""))
        busListening = false
        busy = nil
        if wasLive { startLive() }
    }

    private func ingestBus(_ entries: [BusLogEntry]) {
        guard !entries.isEmpty else { return }
        var stats = busStats
        var ranges = busRanges
        for e in entries {
            let f = e.frame
            var st = stats[f.key] ?? BusStat()
            if st.count > 0 {
                if st.changed.count < f.data.count { st.changed += [UInt8](repeating: 0, count: f.data.count - st.changed.count) }
                for i in 0..<min(st.data.count, f.data.count) { st.changed[i] |= st.data[i] ^ f.data[i] }
            } else {
                st.changed = [UInt8](repeating: 0, count: f.data.count)
            }
            st.count += 1
            st.data = f.data
            stats[f.key] = st
            if let m = busDBC?.messages[f.key] {
                for d in m.decode(f.data) {
                    let v = d.value
                    let k = f.key.text + "." + d.signal.name
                    let old = ranges[k] ?? (v, v)
                    ranges[k] = (min(old.0, v), max(old.1, v))
                }
            }
        }
        busStats = stats
        busRanges = ranges
        busFrames += entries.count
        busLog.append(contentsOf: entries)
        if busLog.count > Self.busLogCap { busLog.removeFirst(busLog.count - Self.busLogCap) }
    }

    /// Re-run min/max over everything heard (after picking a different DBC).
    func recomputeBusRanges() {
        guard let dbc = busDBC else { busRanges = [:]; return }
        var ranges: [String: (Double, Double)] = [:]
        for e in busLog {
            guard let m = dbc.messages[e.frame.key] else { continue }
            for d in m.decode(e.frame.data) {
                let v = d.value
                let k = e.frame.key.text + "." + d.signal.name
                let old = ranges[k] ?? (v, v)
                ranges[k] = (min(old.0, v), max(old.1, v))
            }
        }
        busRanges = ranges
    }

    func saveBusLog() {
        guard !busLog.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CAN log \(Date().formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(BusLogFile.csv(busLog).utf8).write(to: url, options: .atomic)
    }

    /// One row per decoded signal value: time, ID, message, signal, value, unit.
    func saveBusDecoded() {
        guard let dbc = busDBC, !busLog.isEmpty else { return }
        var rows = ["time_s,id,message,signal,value,text,unit"]
        for e in busLog {
            guard let m = dbc.messages[e.frame.key] else { continue }
            for d in m.decode(e.frame.data) {
                let text = d.signal.choice(e.frame.data) ?? ""
                rows.append([String(format: "%.3f", e.t), e.frame.key.text, m.name, d.signal.name, VAGBlocks.format(d.value), text, d.signal.unit]
                    .map { $0.replacingOccurrences(of: ",", with: " ") }.joined(separator: ","))
            }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CAN decoded \(Date().formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(rows.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    /// Open a CAN log saved earlier (this app's CSV) to decode it again — no car needed.
    func openBusLog() {
        guard !busListening else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let entries = BusLogFile.parse(text)
        guard !entries.isEmpty else { busStatus = "That file isn't a CAN log saved by this app."; return }
        clearBus()
        busSource = url.lastPathComponent
        busSeconds = max(0.001, (entries.last?.t ?? 0) - (entries.first?.t ?? 0))
        ingestBus(entries)
    }

    // MARK: - VW measuring blocks (TP2.0, service 21)

    @Published private(set) var blockReadings: [GroupReading] = []
    @Published private(set) var blocksLive = false
    @Published private(set) var blockStatus: String?
    @Published private(set) var blockMinMax: [String: (Double, Double)] = [:]
    @Published private(set) var blockLogCount = 0
    @Published private(set) var blockRound = 0           // increases every live round (never capped)
    private var blockLog: [(Date, [GroupReading])] = []
    private var blockStop = false

    @Published private(set) var blockAddress: UInt8?

    static func blockKey(_ address: UInt8, _ group: UInt8, _ field: Int) -> String {
        String(format: "%02X.%03d.%d", Int(address), Int(group), field + 1)
    }

    /// Name for a measuring-block field: this car's own label first, then the model's shared library.
    func blockLabel(address: UInt8, group: UInt8, field: Int) -> String? {
        let k = Self.blockKey(address, group, field)
        return profile?.blockLabels?[k] ?? libraryMatch?.blockLabels?[k]
    }

    func setBlockLabel(address: UInt8, group: UInt8, field: Int, label: String) {
        guard var p = profile else { return }
        let k = Self.blockKey(address, group, field)
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var d = p.blockLabels ?? [:]
        d[k] = t.isEmpty ? nil : t
        p.blockLabels = d.isEmpty ? nil : d
        saveProfile(p)
        ModuleLibrary.shared.setLabel(make: p.make, model: p.model, vin: vin, key: k, label: t)
        objectWillChange.send()
    }

    func stopBlocks() {
        blockStop = true
        busy = "Stopping…"
    }

    /// Read up to 3 measuring-block groups from one module, once or continuously until Stop.
    func readBlocks(address: UInt8, groups: [UInt8], live: Bool) async {
        guard isConnected, isCAN, !protocolName.contains("29-bit"), busy == nil, !groups.isEmpty else { return }
        let wasLive = isLive
        stopLive()
        blockStop = false
        blockStatus = nil
        blocksLive = live
        blockMinMax = [:]
        blockLog = []
        blockLogCount = 0
        blockAddress = address
        busy = String(format: "Opening module %02X…", Int(address))
        appendLog(String(format: "Measuring blocks: module %02X, groups %@", Int(address), groups.map { String($0) }.joined(separator: ",")))
        let ch: TP20Channel? = (try? await io { elm -> TP20Channel? in
            try elm.tp20Begin()
            let c = TP20Channel(elm: elm, address: address)
            guard try c.open() else { return nil }
            _ = try? c.request([0x10, 0x89])
            return c
        }) ?? nil
        if let ch {
            busy = live ? "Reading measuring blocks live…" : "Reading measuring blocks…"
            var misses = 0
            repeat {
                var round: [GroupReading] = []
                for g in groups {
                    let reply = try? await io { _ in try ch.request([0x21, g]) }
                    round.append(VAGBlocks.reading(group: g, reply: reply))
                }
                blockReadings = round
                blockRound &+= 1
                for g in round {
                    for f in g.fields {
                        guard let v = f.value else { continue }
                        let k = "\(g.group).\(f.index)"
                        let old = blockMinMax[k] ?? (v, v)
                        blockMinMax[k] = (min(old.0, v), max(old.1, v))
                    }
                }
                if live {
                    blockLog.append((Date(), round))
                    if blockLog.count > 50_000 { blockLog.removeFirst(blockLog.count - 50_000) }
                    blockLogCount = blockLog.count
                }
                misses = round.allSatisfy { $0.error == "No answer" } ? misses + 1 : 0
                if misses >= 3 { blockStatus = "The module stopped answering."; break }
            } while live && !blockStop
            _ = try? await io { _ in ch.close() }
        } else {
            blockStatus = String(format: "Module %02X didn't answer. Check the address (run the TP2.0 scan to see which modules this car has).", Int(address))
        }
        _ = try? await io { $0.tp20End() }
        blocksLive = false
        busy = nil
        if wasLive { startLive() }
    }

    // MARK: - Measuring-block explorer (find where a module keeps mileage, service and battery data)

    @Published private(set) var explorerResults: [GroupReading] = []
    @Published private(set) var explorerProgress: Double?
    @Published private(set) var moduleOdometers: [String: Double] = [:]

    /// Read groups 1…last once from one module and keep every group that has data.
    @Published private(set) var explorerAddress: UInt8?

    func exploreBlocks(address: UInt8, first requestedFirst: Int = 1, last requested: Int = 40) async {
        let first = max(0, min(255, requestedFirst))
        let last = max(first, min(255, requested))
        guard isConnected, isCAN, !protocolName.contains("29-bit"), busy == nil else { return }
        let wasLive = isLive
        stopLive()
        explorerResults = []
        explorerAddress = address
        blockStop = false
        blockStatus = nil
        explorerProgress = 0
        busy = String(format: "Exploring module %02X…", Int(address))
        let ch: TP20Channel? = (try? await io { elm -> TP20Channel? in
            try elm.tp20Begin()
            let c = TP20Channel(elm: elm, address: address)
            guard try c.open() else { return nil }
            _ = try? c.request([0x10, 0x89])
            return c
        }) ?? nil
        if let ch {
            var misses = 0
            for g in first...last {
                if blockStop { break }
                explorerProgress = Double(g - first + 1) / Double(last - first + 1)
                busy = String(format: "Module %02X group %03d…", Int(address), g)
                let gg = UInt8(g)
                let reply = try? await io { _ in try ch.request([0x21, gg]) }
                let r = VAGBlocks.reading(group: gg, reply: reply)
                misses = reply == nil ? misses + 1 : 0
                if misses >= 3 { blockStatus = "The module stopped answering."; break }
                if r.error == nil && !r.fields.isEmpty { explorerResults.append(r) }
            }
            _ = try? await io { _ in ch.close() }
            // Mileage kept in this module: fields in km above 100.
            let name = String(format: "%@ (%02X)", TP20.names[address] ?? "Module", Int(address))
            for g in explorerResults {
                for f in g.fields where f.unit == "km" {
                    if let v = f.value, v > 100 { moduleOdometers["\(name) group \(g.groupText)"] = v }
                }
            }
            refreshInspection()
        } else {
            blockStatus = String(format: "Module %02X didn't answer.", Int(address))
        }
        _ = try? await io { $0.tp20End() }
        explorerProgress = nil
        busy = nil
        if wasLive { startLive() }
    }

    func exportBlockCSV() {
        guard let first = blockLog.first else { return }
        var header = ["time"]
        var widths: [UInt8: Int] = [:]
        for g in first.1 {
            widths[g.group] = g.fields.count
            for f in g.fields {
                let name = blockAddress.flatMap { blockLabel(address: $0, group: g.group, field: f.index) }
                header.append(("G\(g.groupText).\(f.index + 1)\(name.map { " \($0)" } ?? "")\(f.unit.isEmpty ? "" : " (\(f.unit))")").replacingOccurrences(of: ",", with: " "))
            }
        }
        var rows = [header.joined(separator: ",")]
        let t0 = first.0
        for (t, round) in blockLog {
            var row = [String(format: "%.2f", t.timeIntervalSince(t0))]
            for g in round {
                let w = widths[g.group] ?? g.fields.count
                for k in 0..<w { row.append(k < g.fields.count ? g.fields[k].text.replacingOccurrences(of: ",", with: " ") : "") }
            }
            rows.append(row.joined(separator: ","))
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Measuring blocks \(Date().formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(rows.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    func tp20ReportText() -> String {
        guard !tp20Reports.isEmpty else { return "" }
        var r = "\n## VW TP2.0 modules\n\n"
        for m in tp20Reports {
            r += "- \(m.addressText) \(m.name): "
            r += m.faultsRead ? (m.faults.isEmpty ? "no faults" : "\(m.faults.count) fault(s)") : (m.note ?? "faults not read")
            r += "\n"
            if !m.identification.isEmpty { r += "    - \(m.identification.joined(separator: " · "))\n" }
            for f in m.faults {
                r += "    - \(f.display) — \(f.description) (status \(String(format: "%02X", f.status)))\n"
                if let c = f.causes { r += "        - Common causes: \(c)\n" }
            }
        }
        return r
    }

    func addSweepHitsToCar() {
        for h in sweepHits { addModuleAddress(h.spec) }
    }

    func saveSweepToLibrary() {
        let mods = sweepHits.map { LibraryModule(spec: $0.spec, name: $0.systemName ?? moduleName($0.spec) ?? "Module \($0.request)") }
        ModuleLibrary.shared.record(make: profile?.make, model: profile?.model, year: profile?.modelYear, vin: vin, modules: mods)
        objectWillChange.send()
        appendLog("Saved \(mods.count) module\(mods.count == 1 ? "" : "s") to the module library")
    }

    func saveScanToLibrary() {
        let mods = moduleReports.filter(\.answered).map { r in
            LibraryModule(spec: r.address,
                          name: r.identification.first(where: { $0.label == "System name" })?.value ?? r.name ?? "Module \(r.address)")
        }
        ModuleLibrary.shared.record(make: profile?.make, model: profile?.model, year: profile?.modelYear, vin: vin, modules: mods)
        objectWillChange.send()
        appendLog("Saved \(mods.count) scanned module\(mods.count == 1 ? "" : "s") to the module library")
    }

    func addModuleAddress(_ a: String) {
        guard let t = ModuleTarget(spec: a), var p = profile else { return }
        var extra = p.extraModuleAddresses ?? []
        if !extra.contains(t.spec) { extra.append(t.spec) }
        p.extraModuleAddresses = extra
        saveProfile(p)
    }

    func clearExtraModuleAddresses() {
        guard var p = profile else { return }
        p.extraModuleAddresses = nil
        saveProfile(p)
    }

    func scanModules(readIDs: Bool) async {
        guard isConnected, isCAN, busy == nil else { return }
        let wasLive = isLive
        stopLive()
        var reports: [ModuleReport] = []
        for addr in moduleAddresses {
            busy = "Scanning module \(addr)…"
            var rep = ModuleReport(address: addr)
            rep.name = moduleName(addr)
            do {
                let msgs = try await io { try $0.requestTo(header: addr, "1902FF", timeout: 2) }
                if let m = msgs.first(where: { $0.firstFrame.first == 0x59 }), let codes = UDS.parseDTCs(m.firstFrame) {
                    rep.answered = true
                    rep.responder = m.ecu
                    rep.dtcs = codes
                } else if let m = msgs.first(where: { $0.firstFrame.first == 0x7F }) {
                    rep.answered = true
                    rep.responder = m.ecu
                    let f = m.firstFrame
                    rep.note = "Answered but didn't report codes this way (\(f.count > 2 ? UDS.nrcText(f[2]) : "refused")). It may use an older protocol — use the brand's tool for this module."
                }
            } catch { }
            if rep.answered && readIDs {
                for item in UDS.identifiers {
                    guard let msgs = try? await io({ try $0.requestTo(header: addr, "22" + item.did, timeout: 1.5) }) else { continue }
                    let echo = hexBytes(item.did)
                    if let f = msgs.map(\.firstFrame).first(where: { $0.count > 3 && $0[0] == 0x62 && Array($0[1...2]) == echo }) {
                        let text = Mode09.text(Array(f.dropFirst(3)))
                        let value = text.isEmpty ? hexString(Array(f.dropFirst(3))) : text
                        if !value.isEmpty { rep.identification.append((item.label, value)) }
                    }
                }
            }
            reports.append(rep)
        }
        moduleReports = reports
        lastModuleScan = Date()
        refreshVerdicts()
        refreshInspection()
        busy = nil
        if wasLive { startLive() }
    }

    func moduleScanReport() -> String {
        let answered = moduleReports.filter(\.answered)
        guard !answered.isEmpty else { return "" }
        var r = "\n## All-module fault codes\n\n"
        for m in answered {
            r += "- Module \(m.address)\(m.name.map { " — \($0)" } ?? "")\(m.responder.isEmpty ? "" : " (replies as \(m.responder))"): "
            r += m.dtcs.isEmpty ? (m.note ?? "no codes") : "\(m.dtcs.count) code\(m.dtcs.count == 1 ? "" : "s")"
            r += "\n"
            for (label, value) in m.identification { r += "    - \(label): \(value)\n" }
            for d in m.dtcs {
                let ft = FailureType.describe(d.ftb, make: profile?.make ?? VINDecoder.manufacturer(vin)).map { " — \($0)" } ?? ""
                r += "    - \(d.display) — \(d.description)\(ft) (\(d.statusText))\n"
            }
        }
        return r
    }

    // MARK: - Menu bar

    var menuBarText: String {
        guard isLive else { return "OBD" }
        let pids = profile?.menuBarPIDs ?? [0x0C, 0x05]
        let parts = pids.compactMap { pid -> String? in
            guard let def = PIDs.def(pid), let v = liveValues[pid] else { return nil }
            return def.format(v, units)
        }
        return parts.isEmpty ? "OBD" : parts.joined(separator: " · ")
    }
}

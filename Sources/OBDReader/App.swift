import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct OBDReaderApp: App {
    @StateObject private var garage: GarageStore
    @StateObject private var session: VehicleSession

    init() {
        let g = GarageStore()
        _garage = StateObject(wrappedValue: g)
        _session = StateObject(wrappedValue: VehicleSession(garage: g))
        // Needed when launched with `swift run` (no .app bundle) so the window comes to front.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("OBD Reader") {
            ContentView()
                .environmentObject(session)
                .environmentObject(garage)
                .frame(minWidth: 1020, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(session)
        } label: {
            if session.isLive {
                Text(session.menuBarText).monospacedDigit()
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case connection = "Connection"
    case garage = "Garage"
    case diagnosis = "Diagnosis"
    case inspection = "Pre-Purchase Check"
    case modules = "All Modules"
    case blocks = "Measuring Blocks"
    case wheels = "Wheel Speed Test"
    case health = "Engine Health"
    case custom = "Custom Readings"
    case codes = "Trouble Codes"
    case tests = "Self-Tests"
    case readiness = "Readiness"
    case smog = "Smog Check"
    case battery = "Battery Test"
    case history = "History"
    case ai = "AI Explanation"
    case dashboard = "Live Dashboard"
    case trip = "Trip"
    case performance = "Performance"
    case turbo = "Turbo & Torque"
    case track = "Track"
    case alerts = "Alerts"
    case vehicle = "Vehicle Info"
    case log = "Adapter Log"
    case imported = "Imported Logs"
    case bus = "CAN Bus Listener"
    case nearby = "Nearby Shops & DMV"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .connection: return "cable.connector"
        case .garage: return "car.2"
        case .diagnosis: return "stethoscope"
        case .inspection: return "magnifyingglass.circle"
        case .modules: return "cpu"
        case .blocks: return "gauge.with.needle"
        case .wheels: return "tirepressure"
        case .health: return "heart.text.square"
        case .custom: return "slider.horizontal.3"
        case .codes: return "exclamationmark.triangle"
        case .tests: return "testtube.2"
        case .readiness: return "checklist"
        case .smog: return "smoke"
        case .battery: return "minus.plus.batteryblock"
        case .history: return "clock.arrow.circlepath"
        case .ai: return "sparkles"
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .trip: return "road.lanes"
        case .performance: return "flag.checkered"
        case .turbo: return "fanblades"
        case .track: return "point.topleft.down.to.point.bottomright.curvepath"
        case .alerts: return "bell"
        case .vehicle: return "info.circle"
        case .log: return "text.alignleft"
        case .imported: return "doc.text.magnifyingglass"
        case .bus: return "dot.radiowaves.left.and.right"
        case .nearby: return "mappin.and.ellipse"
        }
    }

    static let sections: [(String, [SidebarItem])] = [
        ("Car", [.connection, .garage, .vehicle, .nearby]),
        ("Diagnose", [.diagnosis, .inspection, .health, .codes, .modules, .blocks, .wheels, .tests, .readiness, .smog, .battery, .history, .ai]),
        ("Drive", [.dashboard, .custom, .turbo, .trip, .performance, .track, .alerts]),
        ("Advanced", [.bus, .imported, .log]),
    ]
}

struct ContentView: View {
    @EnvironmentObject var s: VehicleSession
    @State private var selection: SidebarItem? = .connection

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarItem.sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { item in
                            Label(item.rawValue, systemImage: item.icon)
                                .badge(badge(for: item))
                                .tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { StatusFooter().padding(10) }
        } detail: {
            Group {
                switch selection ?? .connection {
                case .connection: ConnectionView()
                case .garage: GarageView()
                case .diagnosis: DiagnosisView()
                case .inspection: InspectionView()
                case .modules: AllModulesView()
                case .blocks: MeasuringBlocksView()
                case .wheels: WheelSpeedView()
                case .bus: BusListenerView()
                case .health: HealthView()
                case .custom: CustomReadingsView()
                case .turbo: TurboView()
                case .track: TrackView()
                case .codes: CodesView()
                case .tests: TestsView()
                case .readiness: ReadinessView()
                case .smog: SmogView()
                case .battery: BatteryTestView()
                case .history: HistoryView()
                case .ai: AIExplainView()
                case .dashboard: DashboardView()
                case .trip: TripView()
                case .performance: PerformanceView()
                case .alerts: AlertsView()
                case .vehicle: VehicleInfoView()
                case .log: LogView()
                case .imported: ImportedLogsView()
                case .nearby: NearbyView()
                }
            }
            .overlay(alignment: .top) { AlertBanner() }
            .animation(.easeOut(duration: 0.2), value: s.alertBanner)
            .toolbar {
                ToolbarItemGroup {
                    if let busy = s.busy {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Units", selection: $s.units) {
                        ForEach(UnitSystem.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 190)
                    Button {
                        Task { await s.fullScan() }
                    } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(!s.isConnected || s.busy != nil)
                    Menu {
                        Button("PDF…") { s.exportPDF() }
                        Button("Markdown…") {
                            saveText(s.report(), name: "OBD report.md", type: UTType(filenameExtension: "md") ?? .plainText)
                        }
                    } label: { Label("Export Report", systemImage: "square.and.arrow.up") }
                    .disabled(s.lastScan == nil && s.importedLogs.isEmpty)
                }
            }
        }
        .onChange(of: s.status) { _, new in
            if new == .connected { selection = .diagnosis }
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .codes: return s.dtcs.count
        case .diagnosis: return s.findings.filter { $0.severity >= .attention }.count
        case .tests: return s.tests.filter { !$0.passed }.count
        case .inspection: return s.inspection?.redCount ?? 0
        case .modules: return s.moduleReports.reduce(0) { $0 + $1.dtcs.count }
        default: return 0
        }
    }
}

struct StatusFooter: View {
    @EnvironmentObject var s: VehicleSession
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let b = s.battery {
                Text(String(format: "%.1f V", b)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
    private var color: Color {
        switch s.status {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }
    private var text: String {
        switch s.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .failed: return "Connection failed"
        case .disconnected: return "Not connected"
        }
    }
}

@MainActor
func saveText(_ text: String, name: String, type: UTType) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [type]
    if panel.runModal() == .OK, let url = panel.url {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Address sweep: find which modules a car really has by asking every diagnostic address for its
// identification (UDS 22 F190, read-only) and recording who answers and from which reply address.
// Results go into our own module library (per make/model), which then feeds the All Modules scan.

struct SweepHit: Identifiable, Hashable {
    let request: String       // "713" or "18DA28F1"
    let reply: String         // "77D" or "18DAF128"
    let positive: Bool        // answered with data (62) rather than a refusal (7F)
    var systemName: String?   // from 22 F197, if the module gives it
    var id: String { request }

    /// Spec in the app's address format, with the reply only when it isn't the standard one.
    var spec: String {
        let t = ModuleTarget(request: request)
        return t.replyAddress == reply ? request : "\(request)>\(reply)"
    }
}

extension ELM327 {
    /// Listen broadly for replies: 11-bit IDs 400–7FF, or 29-bit 18DAF1xx. Flow control on.
    func beginSweep() throws {
        if obdProtocol.is29Bit {
            _ = try raw("ATCP18")
            _ = try raw("ATCF18DAF100")
            _ = try raw("ATCM1FFFFF00")
        } else {
            _ = try raw("ATCF400")
            _ = try raw("ATCM400")
        }
        _ = try raw("ATFCSD300000")
        _ = try raw("ATFCSM1")
    }

    func endSweep() {
        _ = try? raw("ATFCSM0")
        _ = try? raw("ATCRA")
        _ = try? raw("ATAR")
        if obdProtocol.is29Bit {
            _ = try? raw("ATCP18")
            _ = try? raw("ATSHDB33F1")
        } else {
            _ = try? raw("ATSH7DF")
        }
    }

    /// Ask one address for its VIN (22 F190). Returns a hit if a module answered, positively or not.
    func probe(_ request: String) -> SweepHit? {
        if request.count == 8 {
            guard (try? raw("ATSH" + String(request.suffix(6)))) != nil else { return nil }
        } else {
            guard (try? raw("ATSH" + request)) != nil else { return nil }
        }
        _ = try? raw("ATFCSH" + request)
        guard let msgs = try? self.request("22F190", timeout: 1.5) else { return nil }
        for m in msgs {
            let f = m.firstFrame
            let positive = f.count >= 3 && f[0] == 0x62 && f[1] == 0xF1 && f[2] == 0x90
            let refused = f.count >= 2 && f[0] == 0x7F && f[1] == 0x22
            guard positive || refused else { continue }
            let reply = obdProtocol.is29Bit ? "18DAF1" + m.ecu : m.ecu
            return SweepHit(request: request, reply: reply, positive: positive)
        }
        return nil
    }

    /// System name (22 F197) from a module during a sweep.
    func systemName(_ request: String) -> String? {
        guard let msgs = try? self.request("22F197", timeout: 1.5) else { return nil }
        for m in msgs {
            let f = m.firstFrame
            if f.count > 3, f[0] == 0x62, f[1] == 0xF1, f[2] == 0x97 {
                let t = Mode09.text(Array(f.dropFirst(3)))
                return t.isEmpty ? nil : t
            }
        }
        return nil
    }
}

// MARK: - Our module library

struct LibraryModule: Codable, Hashable {
    var spec: String
    var name: String
}

struct LibraryModel: Codable, Identifiable, Hashable {
    var make: String
    var model: String
    var years: [Int] = []
    var vinPrefixes: [String] = []   // first 8 VIN characters (maker + model code), never the full VIN
    var modules: [LibraryModule] = []
    var scans = 0
    var updated = Date()
    /// Names for measuring-block fields, keyed "AA.GGG.F" (module address, group, field), e.g. "02.004.2".
    var blockLabels: [String: String]? = nil
    var id: String { ModuleLibrary.key(make: make, model: model) }

    var title: String {
        let yrs = years.sorted()
        let range = yrs.isEmpty ? "" : (yrs.first == yrs.last ? " \(yrs[0])" : " \(yrs.first!)–\(yrs.last!)")
        return "\(make) \(model)\(range)".trimmingCharacters(in: .whitespaces)
    }
}

/// Which modules each make/model has, built from our own sweeps and scans. Stored on this Mac;
/// export/import as .obdmodules files to share.
@MainActor
final class ModuleLibrary: ObservableObject {
    static let shared = ModuleLibrary()
    static let fileExtension = "obdmodules"
    @Published private(set) var models: [LibraryModel] = []

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("OBDReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("module-library.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: url), let m = try? Self.decoder.decode([LibraryModel].self, from: d) { models = m }
    }

    nonisolated static func key(make: String, model: String) -> String {
        (make + "|" + model).lowercased().filter { !$0.isWhitespace }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private func save() { try? Self.encoder.encode(models).write(to: url, options: .atomic) }

    /// The entry for a car: same make + model, or failing that the same VIN maker/model code.
    func match(make: String?, model: String?, vin: String) -> LibraryModel? {
        let mk = make ?? "", md = model ?? ""
        if !mk.isEmpty || !md.isEmpty, let m = models.first(where: { $0.id == Self.key(make: mk, model: md) }) { return m }
        let prefix = String(vin.prefix(8)).uppercased()
        guard prefix.count == 8 else { return nil }
        return models.first { $0.vinPrefixes.contains(prefix) }
    }

    /// Add what one car showed. Merges with what's already known for that make/model.
    func record(make: String?, model: String?, year: Int?, vin: String, modules: [LibraryModule]) {
        guard !modules.isEmpty else { return }
        let prefix = String(vin.prefix(8)).uppercased()
        var mk = (make ?? "").trimmingCharacters(in: .whitespaces)
        var md = (model ?? "").trimmingCharacters(in: .whitespaces)
        if mk.isEmpty && md.isEmpty { mk = "VIN"; md = prefix.isEmpty ? "unknown" : prefix }
        let k = Self.key(make: mk, model: md)
        var entry = models.first { $0.id == k } ?? LibraryModel(make: mk, model: md)
        if let y = year, !entry.years.contains(y) { entry.years.append(y) }
        if prefix.count == 8, !entry.vinPrefixes.contains(prefix) { entry.vinPrefixes.append(prefix) }
        for m in modules {
            if let i = entry.modules.firstIndex(where: { $0.spec == m.spec }) {
                if entry.modules[i].name.hasPrefix("Module ") && !m.name.hasPrefix("Module ") { entry.modules[i].name = m.name }
            } else {
                entry.modules.append(m)
            }
        }
        entry.modules.sort { $0.spec < $1.spec }
        entry.scans += 1
        entry.updated = Date()
        models.removeAll { $0.id == k }
        models.append(entry)
        models.sort { $0.title < $1.title }
        save()
    }

    /// Name a measuring-block field for this make/model (empty label removes it).
    func setLabel(make: String?, model: String?, vin: String, key: String, label: String) {
        let prefix = String(vin.prefix(8)).uppercased()
        var mk = (make ?? "").trimmingCharacters(in: .whitespaces)
        var md = (model ?? "").trimmingCharacters(in: .whitespaces)
        if mk.isEmpty && md.isEmpty { mk = "VIN"; md = prefix.isEmpty ? "unknown" : prefix }
        let k = Self.key(make: mk, model: md)
        guard !label.isEmpty || models.contains(where: { $0.id == k }) else { return }
        var entry = models.first { $0.id == k } ?? LibraryModel(make: mk, model: md)
        if prefix.count == 8, !entry.vinPrefixes.contains(prefix) { entry.vinPrefixes.append(prefix) }
        var labels = entry.blockLabels ?? [:]
        labels[key] = label.isEmpty ? nil : label
        entry.blockLabels = labels.isEmpty ? nil : labels
        entry.updated = Date()
        models.removeAll { $0.id == k }
        models.append(entry)
        models.sort { $0.title < $1.title }
        save()
    }

    func remove(_ m: LibraryModel) {
        models.removeAll { $0.id == m.id }
        save()
    }

    func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Module library.\(Self.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: Self.fileExtension) ?? .json]
        guard panel.runModal() == .OK, let u = panel.url, let d = try? Self.encoder.encode(models) else { return }
        try? d.write(to: u, options: .atomic)
    }

    /// Merge one or more shared library files. Returns how many models were added or updated.
    @discardableResult
    func importFiles() -> Int {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Self.fileExtension) ?? .json, .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return 0 }
        var n = 0
        for u in panel.urls {
            guard let d = try? Data(contentsOf: u), let list = try? Self.decoder.decode([LibraryModel].self, from: d) else { continue }
            for incoming in list {
                let valid = incoming.modules.filter { ModuleTarget(spec: $0.spec) != nil }
                guard !valid.isEmpty || !(incoming.blockLabels ?? [:]).isEmpty else { continue }
                if var e = models.first(where: { $0.id == incoming.id }) {
                    for m in valid where !e.modules.contains(where: { $0.spec == m.spec }) { e.modules.append(m) }
                    var labels = e.blockLabels ?? [:]
                    for (k, v) in incoming.blockLabels ?? [:] where labels[k] == nil { labels[k] = v }
                    e.blockLabels = labels.isEmpty ? nil : labels
                    e.years = Array(Set(e.years + incoming.years)).sorted()
                    e.vinPrefixes = Array(Set(e.vinPrefixes + incoming.vinPrefixes)).sorted()
                    e.modules.sort { $0.spec < $1.spec }
                    e.scans += incoming.scans
                    e.updated = Date()
                    models.removeAll { $0.id == e.id }
                    models.append(e)
                } else {
                    var e = incoming
                    e.modules = valid
                    models.append(e)
                }
                n += 1
            }
        }
        models.sort { $0.title < $1.title }
        save()
        return n
    }
}

// MARK: - Views

struct SweepCard: View {
    @EnvironmentObject var s: VehicleSession
    @State private var confirming = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Find modules (address sweep)").font(.headline)
                    Spacer()
                    if s.sweepRunning {
                        Button("Stop", role: .destructive) { s.stopSweep() }
                    } else {
                        Button("Start sweep") { confirming = true }
                            .disabled(s.busy != nil || !s.isCAN)
                    }
                }
                Text(s.protocolName.contains("29-bit")
                     ? "Asks every diagnostic address 18DA00F1–18DAFEF1 for its identification (a read-only request) and lists the modules that answer. Takes about 2 minutes."
                     : "Asks every diagnostic address 700–7FF for its identification (a read-only request) and lists the modules that answer, with the address they reply from. Takes about 2 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Do it parked, ignition on, engine off. Older modules that only speak a maker's legacy protocol won't answer this request.")
                    .font(.caption).foregroundStyle(.secondary)
                if let p = s.sweepProgress {
                    ProgressView(value: p)
                }
                if !s.sweepHits.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                        ForEach(s.sweepHits) { h in
                            GridRow {
                                Text(h.spec).monospaced()
                                Text(h.systemName ?? s.moduleName(h.spec) ?? s.moduleName(h.request) ?? "—")
                                Text(h.positive ? "answered" : "answered (refused ID read)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.callout)
                    HStack {
                        Button("Add to this car's scan list") { s.addSweepHitsToCar() }
                        Button("Save to our module library") { s.saveSweepToLibrary() }
                    }
                } else if s.sweepProgress == nil, s.lastSweep != nil {
                    Text("No module answered the identification request.").foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Start the address sweep?", isPresented: $confirming) {
            Button("Start (car parked, engine off)") { Task { await s.sweepModules() } }
        } message: {
            Text("The app will send a read-only identification request to each diagnostic address. Nothing is written to the car.")
        }
    }
}

struct LibraryCard: View {
    @EnvironmentObject var s: VehicleSession
    @ObservedObject private var lib = ModuleLibrary.shared
    @State private var showAll = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Our module library").font(.headline)
                    Text("\(lib.models.count) model\(lib.models.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import…") { lib.importFiles() }
                    Button("Export…") { lib.exportFile() }.disabled(lib.models.isEmpty)
                }
                if let m = s.libraryMatch {
                    Text("This car matches \(m.title) — \(m.modules.count) known module\(m.modules.count == 1 ? "" : "s") from \(m.scans) scan\(m.scans == 1 ? "" : "s"), included in the scan list.")
                        .font(.callout)
                } else {
                    Text("Nothing saved for this car yet. Run a sweep or a scan, then save it here. Set make and model in the Garage so other cars of the same model can use it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !s.moduleReports.filter(\.answered).isEmpty {
                    Button("Save last scan's modules to the library") { s.saveScanToLibrary() }
                }
                if !lib.models.isEmpty {
                    DisclosureGroup("All models", isExpanded: $showAll) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(lib.models) { m in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.title).font(.callout.bold())
                                        Text(m.modules.map { "\($0.spec) \($0.name)" }.joined(separator: " · "))
                                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Spacer()
                                    Button("Remove") { lib.remove(m) }.controlSize(.small)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                Text("Saved on this Mac. Files hold make, model, years, the first 8 VIN characters (maker and model code) and module addresses — never the full VIN.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

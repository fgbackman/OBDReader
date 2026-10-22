import Foundation
import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

// MARK: - Logs from other tools (VCDS measuring blocks)
//
// Readings such as transmission oil temperature and hydraulic pressure come from a manufacturer
// module (e.g. VW-group address 02, Auto Trans), not from standard OBD-II, so this app can't
// request them itself. VCDS can, and its "Log" button saves them as a CSV file. Importing that
// file here puts those readings next to the app's own data: charts, min/average/max, unit
// conversion and the exported report.

struct ImportedChannel: Identifiable {
    let id = UUID()
    var name: String
    var unit: String
    var points: [(t: Double, v: Double)]       // seconds from the start of the log

    var values: [Double] { points.map { $0.v } }
    var minValue: Double? { values.min() }
    var maxValue: Double? { values.max() }
    var average: Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
}

struct ImportedLog: Identifiable {
    let id = UUID()
    let fileName: String
    var source = "CSV"
    var details: [String] = []                 // e.g. "VCDS Release 26.9", "Address 02: Auto Trans"
    var channels: [ImportedChannel] = []
    let imported = Date()
}

enum UnitDisplay {
    /// Convert a reading for display in the chosen unit system. Unknown units pass through.
    static func show(_ v: Double, unit: String, _ units: UnitSystem) -> (Double, String) {
        let u = unit.trimmingCharacters(in: .whitespaces)
        let lower = u.lowercased()
        guard units == .us else { return (v, u) }
        if lower == "bar" || lower == "bar abs" { return (v * 14.5038, "psi") }
        if lower == "mbar" { return (v * 0.0145038, "psi") }
        if lower == "kpa" { return (v * 0.145038, "psi") }
        if u == "°C" || lower == "c" || lower == "deg c" || lower == "degc" { return (v * 9 / 5 + 32, "°F") }
        if lower == "km/h" { return (v * 0.621371, "mph") }
        if lower == "km" { return (v * 0.621371, "mi") }
        if lower == "nm" || u == "N·m" { return (v * 0.737562, "lb·ft") }
        return (v, u)
    }

    static func format(_ v: Double, unit: String, _ units: UnitSystem) -> String {
        let (x, u) = show(v, unit: unit, units)
        let digits = abs(x) >= 100 ? 0 : (abs(x) >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f", x) + (u.isEmpty ? "" : " \(u)")
    }
}

/// Reads a VCDS measuring-block log (or any CSV whose value columns sit next to time columns).
/// Deliberately tolerant: VCDS versions differ in header lines, and values may carry units
/// ("59.0°C", "51.37 bar"). Columns named STAMP/TIME hold timestamps; every other named column
/// is a reading, timed by the nearest time column to its left.
enum ImportedLogParser {
    static func parse(_ text: String, fileName: String) -> ImportedLog? {
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map(splitCSV)

        var log = ImportedLog(fileName: fileName)

        // Header: the first row with a time column and at least one other named column.
        guard let h = rows.firstIndex(where: { row in
            row.contains(where: isTimeHeader) && row.contains(where: { !$0.isEmpty && !isTimeHeader($0) && !isMarker($0) })
        }) else { return nil }

        // Lines above the header are metadata (tool version, module address, group numbers).
        for row in rows[..<h] {
            let line = row.filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.localizedCaseInsensitiveContains("VCDS") { log.source = "VCDS" }
            if log.details.count < 6 { log.details.append(line) }
        }

        let header = rows[h]
        var columns: [(index: Int, timeIndex: Int?, name: String)] = []
        var lastTime: Int?
        var seen: [String: Int] = [:]
        for (i, cell) in header.enumerated() {
            if isTimeHeader(cell) { lastTime = i; continue }
            if cell.isEmpty || isMarker(cell) { continue }
            seen[cell, default: 0] += 1
            let name = seen[cell]! > 1 ? "\(cell) (\(seen[cell]!))" : cell
            columns.append((i, lastTime, name))
        }
        guard !columns.isEmpty else { return nil }

        // Optional units row right after the header (non-numeric text under the value columns).
        var units = Array(repeating: "", count: columns.count)
        var dataStart = h + 1
        if dataStart < rows.count {
            let next = rows[dataStart]
            let texty = columns.contains { c in
                c.index < next.count && !next[c.index].isEmpty && number(next[c.index]) == nil
            }
            if texty {
                for (k, c) in columns.enumerated() where c.index < next.count { units[k] = next[c.index] }
                dataStart += 1
            }
        }

        var points = Array(repeating: [(t: Double, v: Double)](), count: columns.count)
        var rowNumber = 0.0
        var t0: Double?
        for row in rows[dataStart...] {
            guard row.contains(where: { number($0) != nil }) else { continue }
            rowNumber += 1
            for (k, c) in columns.enumerated() where c.index < row.count {
                guard let parsed = number(row[c.index]) else { continue }
                let v = parsed.0
                if units[k].isEmpty, !parsed.1.isEmpty { units[k] = parsed.1 }
                var t = rowNumber
                if let ti = c.timeIndex, ti < row.count, let stamp = number(row[ti]) { t = stamp.0 }
                if t0 == nil { t0 = t }
                points[k].append((t - (t0 ?? 0), v))
            }
        }

        log.channels = columns.enumerated().compactMap { k, c in
            points[k].isEmpty ? nil : ImportedChannel(name: c.name, unit: units[k], points: points[k])
        }
        return log.channels.isEmpty ? nil : log
    }

    private static func isTimeHeader(_ s: String) -> Bool {
        let u = s.uppercased()
        return u == "STAMP" || u == "TIME" || u == "TIMESTAMP" || u.hasPrefix("TIME (")
    }
    private static func isMarker(_ s: String) -> Bool { s.uppercased() == "MARKER" }

    /// Leading number in a cell, plus any unit text after it ("51.37 bar" → (51.37, "bar")).
    static func number(_ cell: String) -> (Double, String)? {
        let s = cell.trimmingCharacters(in: .whitespaces)
        var end = s.startIndex
        var sawDigit = false
        for ch in s {
            if ch.isNumber { sawDigit = true }
            else if !(ch == "." || ch == "-" || ch == "+") { break }
            end = s.index(after: end)
        }
        guard sawDigit, let v = Double(s[s.startIndex..<end]) else { return nil }
        let unit = s[end...].trimmingCharacters(in: .whitespaces)
        return (v, unit)
    }

    /// Minimal CSV split: commas (or semicolons in some locales), double quotes, and the leading
    /// apostrophe VCDS puts before group numbers.
    static func splitCSV(_ line: String) -> [String] {
        let sep: Character = line.filter { $0 == ";" }.count > line.filter { $0 == "," }.count ? ";" : ","
        var out: [String] = []
        var cur = ""
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == sep && !quoted { out.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        out.append(cur)
        return out.map { cell in
            var c = cell.trimmingCharacters(in: .whitespaces)
            if c.hasPrefix("'") { c.removeFirst() }
            return c
        }
    }
}

// MARK: - Session hooks

extension VehicleSession {
    func importLogFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
                ?? String(decoding: data, as: UTF8.self)
            if AutoScanParser.looks(like: text) {
                if let scan = AutoScanParser.parse(text, fileName: url.lastPathComponent) {
                    autoScans.append(scan)
                } else {
                    importFailures.append(url.lastPathComponent)
                }
                continue
            }
            if let log = ImportedLogParser.parse(text, fileName: url.lastPathComponent) {
                importedLogs.append(log)
            } else {
                importFailures.append(url.lastPathComponent)
            }
        }
    }

    func removeImportedLog(_ id: UUID) {
        importedLogs.removeAll { $0.id == id }
        autoScans.removeAll { $0.id == id }
    }

    /// Report section for imported logs (min / average / max per reading).
    func importedLogsReport() -> String {
        guard !importedLogs.isEmpty || !autoScans.isEmpty else { return "" }
        var r = "\n## Imported logs\n\n"
        for scan in autoScans { r += scan.markdown() }
        for log in importedLogs {
            r += "- **\(log.fileName)** (\(log.source))\(log.details.isEmpty ? "" : " — " + log.details.prefix(2).joined(separator: "; "))\n"
            for c in log.channels {
                guard let lo = c.minValue, let hi = c.maxValue, let avg = c.average else { continue }
                r += "    - \(c.name): min \(UnitDisplay.format(lo, unit: c.unit, units)), "
                r += "avg \(UnitDisplay.format(avg, unit: c.unit, units)), max \(UnitDisplay.format(hi, unit: c.unit, units))"
                r += " (\(c.points.count) samples)\n"
            }
        }
        return r
    }
}

// MARK: - Page

struct ImportedLogsView: View {
    @EnvironmentObject var s: VehicleSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    PageHeader(title: "Imported Logs",
                               subtitle: "Readings from manufacturer modules, logged with VCDS and opened here")
                    Spacer()
                    Button("Open log…") { s.importLogFiles() }.buttonStyle(.borderedProminent)
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Transmission oil pressure and temperature, and other module readings").font(.headline)
                        Text("Those values live in the car's own modules (for example address 02, Auto Trans), not in standard OBD-II, so this app doesn't request them itself. In VCDS, open the module, go to Measuring Blocks, pick the groups, press Log, then Start. Bring the saved .CSV here. VCDS Auto-Scan reports (the .TXT it saves) open here too and list every module's faults.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if !s.importFailures.isEmpty {
                    Label("Couldn't read: \(s.importFailures.joined(separator: ", ")). Send me the file and I'll adjust the reader.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if s.importedLogs.isEmpty && s.autoScans.isEmpty {
                    Text("No logs imported yet.").foregroundStyle(.secondary)
                }
                ForEach(s.autoScans) { scan in
                    AutoScanCard(report: scan) { s.removeImportedLog(scan.id) }
                }
                ForEach(s.importedLogs) { log in
                    ImportedLogCard(log: log, units: s.units) { s.removeImportedLog(log.id) }
                }
            }
            .padding(24)
        }
    }
}

struct ImportedLogCard: View {
    let log: ImportedLog
    let units: UnitSystem
    let onRemove: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(log.fileName).font(.headline)
                    Text(log.source).font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive, action: onRemove) { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                }
                ForEach(log.details, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(log.channels) { ChannelChart(channel: $0, units: units) }
                }
            }
        }
    }
}

struct ChannelChart: View {
    let channel: ImportedChannel
    let units: UnitSystem

    var body: some View {
        let shown = channel.points.map { p -> (Double, Double) in
            (p.t, UnitDisplay.show(p.v, unit: channel.unit, units).0)
        }
        let unitLabel = UnitDisplay.show(0, unit: channel.unit, units).1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(channel.name).font(.subheadline.weight(.semibold))
                Spacer()
                if let last = channel.points.last {
                    Text(UnitDisplay.format(last.v, unit: channel.unit, units)).monospacedDigit()
                }
            }
            Chart {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Seconds", p.0), y: .value(unitLabel.isEmpty ? "Value" : unitLabel, p.1))
                }
            }
            .frame(height: 110)
            HStack(spacing: 14) {
                if let lo = channel.minValue { Text("min \(UnitDisplay.format(lo, unit: channel.unit, units))") }
                if let a = channel.average { Text("avg \(UnitDisplay.format(a, unit: channel.unit, units))") }
                if let hi = channel.maxValue { Text("max \(UnitDisplay.format(hi, unit: channel.unit, units))") }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

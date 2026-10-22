import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Custom readings (manufacturer data, user-defined, read-only)
//
// Each car brand keeps extra readings (oil pressure, transmission temperature…) at its own module
// addresses and data identifiers. Instead of shipping a brand database, the user (or a shared
// definition file) supplies: which module to ask, the read request, and a formula for the reply.
// Only read services are allowed — the app never sends write, routine, reset or security requests.

struct CustomPID: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var header: String = "7E0"      // module request address: 3 hex digits (11-bit CAN) or 8 (29-bit)
    var request: String             // service + identifier, e.g. "221001" (UDS) or "015C" (standard)
    var formula: String             // A = first data byte after the echoed identifier, B = second…
    var unit: String = ""
    var minValue: Double?
    var maxValue: Double?
    var enabled = true
    /// Bit-field decoding (OBDb imports) used instead of the formula.
    var bits: BitField? = nil
    /// Where the definition came from (e.g. OBDb credit line).
    var source: String? = nil

    /// Read-only services: 01 (standard data), 21 (KWP read by local ID), 22 (UDS read by identifier).
    static let allowedServices: Set<String> = ["01", "21", "22"]

    init(name: String, header: String = "7E0", request: String, formula: String, unit: String = "",
         minValue: Double? = nil, maxValue: Double? = nil, enabled: Bool = true) {
        self.name = name; self.header = header; self.request = request; self.formula = formula
        self.unit = unit; self.minValue = minValue; self.maxValue = maxValue; self.enabled = enabled
    }

    // Tolerant decoding so hand-written or shared files without ids still load.
    enum CodingKeys: String, CodingKey { case id, name, header, request, formula, unit, minValue, maxValue, enabled, bits, source }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        header = (try? c.decodeIfPresent(String.self, forKey: .header)) ?? "7E0"
        request = try c.decode(String.self, forKey: .request)
        formula = try c.decode(String.self, forKey: .formula)
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        minValue = try? c.decodeIfPresent(Double.self, forKey: .minValue)
        maxValue = try? c.decodeIfPresent(Double.self, forKey: .maxValue)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        bits = try? c.decodeIfPresent(BitField.self, forKey: .bits)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }

    /// Value from the reply's data bytes (bit field if set, otherwise the formula).
    func compute(_ bytes: [UInt8]) throws -> Double {
        if let b = bits {
            guard let v = b.value(bytes) else { throw Formula.FormulaError.bad("not available (short reply or no-value marker)") }
            return v
        }
        return try Formula.evaluate(formula, bytes: bytes)
    }

    /// Text for an enumerated value (OBDb maps), e.g. "Third gear".
    func mapped(_ v: Double) -> String? {
        guard let b = bits, let m = b.map else { return nil }
        let raw = (v - b.add) * (b.div == 0 ? 1 : b.div) / (b.mul == 0 ? 1 : b.mul)   // maps are keyed by raw value
        return m[String(Int(raw.rounded()))]
    }

    var cleanHeader: String { ModuleTarget(spec: header)?.spec ?? header.uppercased().filter(\.isHexDigit) }
    var cleanRequest: String { request.uppercased().filter(\.isHexDigit) }

    /// nil when valid, otherwise what's wrong.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        if ModuleTarget(spec: header) == nil { return "Module address must be 3 hex digits (e.g. 7E0), 8 (e.g. 18DA10F1), or with a reply address (713>77D)." }
        let r = cleanRequest
        if r.count < 4 || r.count % 2 != 0 { return "Request must be whole bytes, e.g. 221001." }
        if !Self.allowedServices.contains(String(r.prefix(2))) {
            return "Only read requests are allowed (services 01, 21, 22)."
        }
        if bits == nil, let e = Formula.check(formula) { return "Formula: \(e)" }
        return nil
    }

    /// Data bytes from a positive reply, or a readable error.
    func extract(_ msgs: [ECUMessage]) -> Result<[UInt8], CustomPIDError> {
        let req = hexBytes(cleanRequest)
        guard let service = req.first else { return .failure(.message("Empty request")) }
        let echo = Array(req.dropFirst())
        for m in msgs {
            let f = m.firstFrame
            if f.count >= 3, f[0] == 0x7F, f[1] == service {
                return .failure(.message(String(format: "The module refused it (code %02X — %@)", Int(f[2]), UDS.nrcText(f[2]))))
            }
            if f.count >= 1 + echo.count, f[0] == service &+ 0x40, Array(f[1..<(1 + echo.count)]) == echo {
                return .success(Array(f.dropFirst(1 + echo.count)))
            }
        }
        return .failure(.message("No matching reply"))
    }
}

enum CustomPIDError: Error { case message(String) }

// MARK: - Formula
//
// Variables A…Z are the reply's data bytes. Operators: + - * / % & | << >> and parentheses.
// Functions: signed(x) (8-bit), signed16(x), bit(x, n), min(a, b), max(a, b), abs(x).
// {A:3} is accepted as shorthand for bit(A, 3).

enum Formula {
    static func check(_ text: String) -> String? {
        do { _ = try evaluate(text, bytes: Array(repeating: 0, count: 26)); return nil }
        catch FormulaError.bad(let s) { return s }
        catch { return "\(error)" }
    }

    static func evaluate(_ text: String, bytes: [UInt8]) throws -> Double {
        var p = Parser(tokens: try tokenize(preprocess(text)), bytes: bytes)
        let v = try p.expression()
        guard p.atEnd else { throw FormulaError.bad("unexpected \"\(p.peekText)\"") }
        return v
    }

    enum FormulaError: Error { case bad(String) }

    private static func preprocess(_ s: String) -> String {
        // {A:3} → bit(A,3)
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "{", let close = s[i...].firstIndex(of: "}") {
                let inner = s[s.index(after: i)..<close].split(separator: ":")
                if inner.count == 2 { out += "bit(\(inner[0]),\(inner[1]))"; i = s.index(after: close); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }

    enum Token: Equatable { case num(Double), ident(String), op(String) }

    private static func tokenize(_ s: String) throws -> [Token] {
        var t: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                if c == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
                    j = i + 2
                    while j < chars.count, chars[j].isHexDigit { j += 1 }
                    guard let v = Int(String(chars[(i + 2)..<j]), radix: 16) else { throw FormulaError.bad("bad hex number") }
                    t.append(.num(Double(v))); i = j; continue
                }
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let v = Double(String(chars[i..<j])) else { throw FormulaError.bad("bad number") }
                t.append(.num(v)); i = j; continue
            }
            if c.isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber { j += 1 }
                t.append(.ident(String(chars[i..<j]))); i = j; continue
            }
            if i + 1 < chars.count, (c == "<" && chars[i + 1] == "<") || (c == ">" && chars[i + 1] == ">") {
                t.append(.op(String([c, chars[i + 1]]))); i += 2; continue
            }
            if "+-*/%&|(),".contains(c) { t.append(.op(String(c))); i += 1; continue }
            throw FormulaError.bad("can't use \"\(c)\"")
        }
        return t
    }

    private struct Parser {
        let tokens: [Token]
        let bytes: [UInt8]
        var pos = 0
        init(tokens: [Token], bytes: [UInt8]) { self.tokens = tokens; self.bytes = bytes }

        var atEnd: Bool { pos >= tokens.count }
        var peekText: String {
            guard pos < tokens.count else { return "end" }
            switch tokens[pos] { case .num(let v): return "\(v)"; case .ident(let s), .op(let s): return s }
        }
        mutating func take(_ op: String) -> Bool {
            if pos < tokens.count, tokens[pos] == .op(op) { pos += 1; return true }
            return false
        }

        /// Safe Double → Int for bit operations (NaN/∞ become 0, huge values are clamped).
        static func int(_ v: Double) -> Int { v.isFinite ? Int(Swift.max(Swift.min(v, 1e15), -1e15)) : 0 }

        mutating func expression() throws -> Double { try orExpr() }
        mutating func orExpr() throws -> Double {
            var v = try andExpr()
            while take("|") { v = Double(Self.int(v) | Self.int(try andExpr())) }
            return v
        }
        mutating func andExpr() throws -> Double {
            var v = try shiftExpr()
            while take("&") { v = Double(Self.int(v) & Self.int(try shiftExpr())) }
            return v
        }
        mutating func shiftExpr() throws -> Double {
            var v = try addExpr()
            while true {
                if take("<<") { v = Double(Self.int(v) << Self.int(try addExpr())) }
                else if take(">>") { v = Double(Self.int(v) >> Self.int(try addExpr())) }
                else { return v }
            }
        }
        mutating func addExpr() throws -> Double {
            var v = try mulExpr()
            while true {
                if take("+") { v += try mulExpr() }
                else if take("-") { v -= try mulExpr() }
                else { return v }
            }
        }
        mutating func mulExpr() throws -> Double {
            var v = try unary()
            while true {
                if take("*") { v *= try unary() }
                else if take("/") {
                    let d = try unary()
                    guard d != 0 else { return .nan }
                    v /= d
                } else if take("%") {
                    let d = try unary()
                    guard d != 0 else { return .nan }
                    v = v.truncatingRemainder(dividingBy: d)
                } else { return v }
            }
        }
        mutating func unary() throws -> Double {
            if take("-") { return -(try unary()) }
            if take("+") { return try unary() }
            return try primary()
        }
        mutating func primary() throws -> Double {
            guard pos < tokens.count else { throw FormulaError.bad("ends too early") }
            let tok = tokens[pos]; pos += 1
            switch tok {
            case .num(let v): return v
            case .op("("):
                let v = try expression()
                guard take(")") else { throw FormulaError.bad("missing )") }
                return v
            case .ident(let name):
                if take("(") {
                    var args: [Double] = []
                    if !take(")") {
                        repeat { args.append(try expression()) } while take(",")
                        guard take(")") else { throw FormulaError.bad("missing ) after \(name)") }
                    }
                    return try call(name.lowercased(), args)
                }
                let up = name.uppercased()
                guard up.count == 1, let ch = up.unicodeScalars.first, (65...90).contains(ch.value) else {
                    throw FormulaError.bad("unknown name \"\(name)\"")
                }
                let idx = Int(ch.value) - 65
                guard idx < bytes.count else { throw FormulaError.bad("reply has no byte \(up)") }
                return Double(bytes[idx])
            case .op(let o): throw FormulaError.bad("unexpected \"\(o)\"")
            }
        }
        func call(_ f: String, _ a: [Double]) throws -> Double {
            func need(_ n: Int) throws { guard a.count == n else { throw FormulaError.bad("\(f) needs \(n) value\(n == 1 ? "" : "s")") } }
            switch f {
            case "signed", "signed8": try need(1); return Double(Int8(truncatingIfNeeded: Self.int(a[0])))
            case "signed16": try need(1); return Double(Int16(truncatingIfNeeded: Self.int(a[0])))
            case "bit": try need(2); return Double((Self.int(a[0]) >> Self.int(a[1])) & 1)
            case "min": try need(2); return Swift.min(a[0], a[1])
            case "max": try need(2); return Swift.max(a[0], a[1])
            case "abs": try need(1); return Swift.abs(a[0])
            default: throw FormulaError.bad("unknown function \(f)")
            }
        }
    }
}

// MARK: - Shared definition files (JSON) and CSV

enum CustomPIDFiles {
    static let fileExtension = "obdpids"

    static func exportJSON(_ list: [CustomPID]) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(list)
    }

    static func exportCSV(_ list: [CustomPID]) -> String {
        func q(_ s: String) -> String { s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        var out = "Name,Header,Request,Formula,Unit,Min,Max\n"
        for p in list where p.bits == nil {      // bit-field (OBDb) readings only round-trip through JSON
            let lo: String = p.minValue.map { String($0) } ?? ""
            let hi: String = p.maxValue.map { String($0) } ?? ""
            let row: [String] = [q(p.name), p.cleanHeader, p.cleanRequest, q(p.formula), q(p.unit), lo, hi]
            out += row.joined(separator: ",") + "\n"
        }
        return out
    }

    /// JSON (this app's format) or a CSV with a header row. Recognised CSV columns (any order,
    /// case-insensitive): name, header, request / pid / modeandpid, formula / equation, unit(s), min, max.
    static func load(_ data: Data) -> [CustomPID] {
        if let list = try? JSONDecoder().decode([CustomPID].self, from: data) { return list }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let headerLine = lines.first else { return [] }
        let cols = ImportedLogParser.splitCSV(headerLine).map { $0.lowercased() }
        func col(_ names: [String]) -> Int? { cols.firstIndex { c in names.contains { c == $0 || c.replacingOccurrences(of: " ", with: "") == $0 } } }
        guard let iName = col(["name"]), let iReq = col(["request", "pid", "modeandpid"]),
              let iF = col(["formula", "equation"]) else { return [] }
        let iHdr = col(["header"]), iUnit = col(["unit", "units"]), iMin = col(["min", "minvalue"]), iMax = col(["max", "maxvalue"])
        return lines.dropFirst().compactMap { line in
            let c = ImportedLogParser.splitCSV(line)
            func at(_ i: Int?) -> String { i.flatMap { $0 < c.count ? c[$0] : nil } ?? "" }
            guard !at(iName).isEmpty, !at(iReq).isEmpty, !at(iF).isEmpty else { return nil }
            let hdr = at(iHdr)
            return CustomPID(name: at(iName), header: hdr.isEmpty ? "7E0" : hdr, request: at(iReq), formula: at(iF),
                             unit: at(iUnit), minValue: Double(at(iMin)), maxValue: Double(at(iMax)))
        }
    }
}

// MARK: - Module-addressed requests on the adapter

extension ELM327 {
    /// Send one request to a specific module address, then put the adapter back on the normal
    /// broadcast address. CAN cars only. Flow control is pointed at the same module so replies
    /// longer than one frame arrive.
    /// Send a read request to one module. `header` is a module address spec:
    /// "7E0", "713>77D" (reply address), "6F1/12>612" (extended address byte), or "18DA10F1".
    func requestTo(header: String, _ command: String, timeout: TimeInterval = 2) throws -> [ECUMessage] {
        guard obdProtocol.isCAN else { throw CustomPIDError.message("Module addressing needs a CAN car (most 2008+)") }
        guard let t = ModuleTarget(spec: header) else { throw CustomPIDError.message("Bad module address \(header)") }
        if t.is29Bit != obdProtocol.is29Bit {
            throw CustomPIDError.message(t.is29Bit
                ? "\(t.request) is a 29-bit address, but this car answered on 11-bit CAN."
                : "\(t.request) is an 11-bit address, but this car answered on 29-bit CAN.")
        }
        let h = t.request
        if t.is29Bit {
            _ = try raw("ATCP" + String(h.prefix(2)))
            _ = try raw("ATSH" + String(h.suffix(6)))
        } else {
            _ = try raw("ATSH" + h)
        }
        if let e = t.ext { _ = try raw("ATCEA" + e) }
        // Listen only for this module's reply address. Without this the adapter's automatic
        // filter only passes 7E8–7EF, so modules like 713→77D look silent.
        if let r = t.replyAddress { _ = try raw("ATCRA" + r) }
        _ = try raw("ATFCSH" + h)
        _ = try raw("ATFCSD" + (t.ext ?? "") + "300000")
        _ = try raw("ATFCSM1")
        defer {
            _ = try? raw("ATFCSM0")
            if t.ext != nil { _ = try? raw("ATCEA") }
            if t.replyAddress != nil { _ = try? raw("ATCRA") }
            if obdProtocol.is29Bit {
                _ = try? raw("ATCP18")
                _ = try? raw("ATSHDB33F1")
            } else {
                _ = try? raw("ATSH7DF")
            }
        }
        if t.ext != nil {
            let lines = clean(try raw(command, timeout: timeout))
            try checkErrors(lines, command: command)
            return ELM327.parseCANLines(lines, is29Bit: false, extendedAddressing: true)
        }
        return try request(command, timeout: timeout)
    }
}

// MARK: - Page

struct CustomReadingsView: View {
    @EnvironmentObject var s: VehicleSession
    @State private var editing: CustomPID?
    @State private var isNew = false
    @State private var search = ""
    @State private var onlyEnabled = false

    private var shown: [CustomPID] {
        guard s.customPIDs.count > 8 else { return s.customPIDs }
        return s.customPIDs.filter { p in
            (!onlyEnabled || p.enabled) &&
            (search.isEmpty || p.name.localizedCaseInsensitiveContains(search) || p.cleanRequest.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    PageHeader(title: "Custom Readings",
                               subtitle: "Manufacturer data you define: module address, read request and formula")
                    Spacer()
                    Button(s.customLive ? "Stop" : "Start reading") { s.toggleCustomLive() }
                        .disabled(!s.isConnected || s.customPIDs.isEmpty)
                    Button("Read once") { Task { await s.readCustomOnce() } }
                        .disabled(!s.isConnected || s.customPIDs.isEmpty || s.busy != nil)
                }
                if s.profile == nil {
                    Text("Connect to a car first — definitions are saved per car, by VIN.").foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Add reading…") {
                            isNew = true
                            editing = CustomPID(name: "", request: "22", formula: "A")
                        }
                        Button("Import…") { s.importCustomPIDs() }
                        Button("Get from OBDb") { Task { await s.fetchOBDb() } }
                            .help("Download this model's community readings from OBDb (needs make and model in the Garage)")
                            .disabled((s.profile?.make ?? "").isEmpty || (s.profile?.model ?? "").isEmpty)
                        Menu("Export") {
                            Button("Definition file (.\(CustomPIDFiles.fileExtension))…") { s.exportCustomPIDs(csv: false) }
                            Button("CSV…") { s.exportCustomPIDs(csv: true) }
                        }
                        .frame(width: 110)
                        .disabled(s.customPIDs.isEmpty)
                    }
                    if !s.isCAN && s.isConnected {
                        Label("This car isn't on CAN, so module-addressed reads aren't available.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if s.customPIDs.isEmpty {
                        Text("No custom readings yet. Add one, or import a definition file someone has shared for this model.")
                            .foregroundStyle(.secondary)
                    }
                    if let st = s.obdbStatus { Text(st).font(.caption).foregroundStyle(.secondary) }
                    if s.customPIDs.count > 8 {
                        HStack {
                            TextField("Search readings", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
                            Toggle("Only enabled", isOn: $onlyEnabled).toggleStyle(.checkbox)
                            Spacer()
                            Button("Enable shown") { s.setCustomEnabled(Set(shown.map(\.id)), true) }
                            Button("Disable shown") { s.setCustomEnabled(Set(shown.map(\.id)), false) }
                        }
                        Text("\(s.customPIDs.filter(\.enabled).count) of \(s.customPIDs.count) enabled. Only enabled readings are read — fewer means faster updates.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if s.customPIDs.contains(where: { $0.source?.hasPrefix("OBDb") == true }) {
                        Text(OBDb.licenseNote).font(.caption2).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(shown) { p in
                            CustomPIDCard(pid: p, value: s.customValues[p.id], error: s.customErrors[p.id],
                                          history: s.customHistory[p.id] ?? [], units: s.units) {
                                isNew = false
                                editing = p
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How it works").font(.headline)
                        Text("Each brand keeps extra readings at its own module addresses. A definition says which module to ask (e.g. 7E0 = engine, 7E1 = transmission on many cars), the read request (e.g. 22 + a 4-digit identifier), and how to turn the reply into a number: A is the first data byte, B the second, so a 2-byte value is (A*256+B). Only read requests (services 01, 21, 22) are allowed. Definitions come from service information or from people who've worked them out for a model.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(24)
        }
        .sheet(item: $editing) { p in
            CustomPIDEditor(draft: p, isNew: isNew) { saved in
                s.upsertCustomPID(saved)
                editing = nil
            } onDelete: {
                s.deleteCustomPID(p.id)
                editing = nil
            } onCancel: { editing = nil }
        }
    }
}

struct CustomPIDCard: View {
    let pid: CustomPID
    let value: Double?
    let error: String?
    let history: [Double]
    let units: UnitSystem
    let onEdit: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(pid.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.borderless)
                }
                Text(value.map { pid.mapped($0) ?? UnitDisplay.format($0, unit: pid.unit, units) } ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                if let error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Sparkline(values: history).frame(height: 24)
                Text("\(pid.cleanHeader) · \(pid.cleanRequest) · \(pid.formula)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if let src = pid.source { Text(src).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .opacity(pid.enabled ? 1 : 0.5)
    }
}

struct CustomPIDEditor: View {
    @State var draft: CustomPID
    let isNew: Bool
    let onSave: (CustomPID) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    @State private var testBytes = "0F A0"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New custom reading" : "Edit custom reading").font(.title2.bold())
            Form {
                TextField("Name", text: $draft.name)
                TextField("Module address (e.g. 7E0)", text: $draft.header)
                TextField("Read request (e.g. 221001)", text: $draft.request)
                TextField("Formula (e.g. (A*256+B)/1000)", text: $draft.formula)
                TextField("Unit (e.g. bar, °C, kPa)", text: $draft.unit)
                Toggle("Enabled", isOn: $draft.enabled)
            }
            HStack {
                Text("Try the formula with reply bytes:")
                TextField("hex bytes", text: $testBytes).frame(width: 140).textFieldStyle(.roundedBorder)
                Text(testResult).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            if let p = draft.problem {
                Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                if !isNew { Button("Delete", role: .destructive, action: onDelete) }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.problem != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var testResult: String {
        let bytes = hexBytes(testBytes.uppercased().filter(\.isHexDigit))
        do { return "= " + String(format: "%.4g", try draft.compute(bytes)) + (draft.unit.isEmpty ? "" : " \(draft.unit)") }
        catch Formula.FormulaError.bad(let m) { return m }
        catch { return "error" }
    }
}

import Foundation
import AppKit
import Security

// MARK: - California smog check predictor

/// Estimates the OBD part of a California Smog Check using BAR's published fail criteria:
/// check-engine light commanded on, permanent codes (2010+), and readiness-monitor limits
/// (1996–99 gas: one incomplete allowed; 2000+ gas: only EVAP may be incomplete;
/// 1998–2006 diesel: none; 2007+ diesel: particulate filter / NMHC only).
struct SmogVerdict {
    enum Result: String { case pass = "Likely to pass", fail = "Would fail", unknown = "Can't tell" }
    let result: Result
    let reasons: [String]
    let notes: [String]

    static func evaluate(readiness: Readiness?, dtcs: [DTC], modelYear: Int?, isDiesel: Bool,
                         warmUps: Double?, kmSinceClear: Double?) -> SmogVerdict {
        guard let r = readiness else {
            return SmogVerdict(result: .unknown, reasons: ["The car didn't report readiness status."],
                               notes: ["No OBD communication is itself a smog-check failure — check the connection and try again."])
        }
        var reasons: [String] = []
        var notes: [String] = []
        let year = modelYear ?? 2000
        if modelYear == nil { notes.append("Model year unknown — assumed 2000 or newer. Set it in the Garage for an exact answer.") }
        let diesel = isDiesel || r.isDiesel

        if r.milOn {
            reasons.append("Check-engine light is commanded on\(r.dtcCount > 0 ? " with \(r.dtcCount) code\(r.dtcCount == 1 ? "" : "s")" : "").")
        }

        let permanent = dtcs.filter { $0.kind == .permanent }
        if !permanent.isEmpty && year >= 2010 {
            let codes = permanent.map(\.code).joined(separator: ", ")
            if let w = warmUps, let km = kmSinceClear, w >= 15, km >= 321.9 {
                notes.append("Permanent code \(codes) present, but the car has 15+ warm-ups and 200+ miles since codes were cleared — BAR may exempt it.")
            } else {
                reasons.append("Permanent code \(codes) (2010+ cars fail with permanent codes until the car clears them itself after repeated good drives).")
            }
        }

        let incomplete = r.monitors.filter { !$0.complete }.map(\.name)
        let blocking: [String]
        if diesel {
            blocking = year >= 2007 ? incomplete.filter { $0 != "PM filter" && $0 != "NMHC catalyst" } : incomplete
        } else if year >= 2000 {
            blocking = incomplete.filter { $0 != "Evaporative system" }
        } else {
            blocking = incomplete.count > 1 ? incomplete : []
        }
        if !blocking.isEmpty {
            reasons.append("Readiness monitor\(blocking.count == 1 ? "" : "s") not complete: \(blocking.joined(separator: ", ")). Drive normally for a few days (mix of highway and town, overnight cold starts) and re-check.")
        } else if !incomplete.isEmpty {
            notes.append("\(incomplete.joined(separator: ", ")) not complete, which is allowed for this car.")
        }

        if dtcs.contains(where: { $0.kind == .pending }) {
            notes.append("Pending codes won't fail the test by themselves but may turn into stored codes (and light the check-engine light) soon.")
        }
        notes.append("This only predicts the OBD portion. The station also does a visual inspection and functional checks.")

        return SmogVerdict(result: reasons.isEmpty ? .pass : .fail, reasons: reasons, notes: notes)
    }
}

// MARK: - Battery / cranking test

struct VoltageSample: Identifiable {
    let id = UUID()
    let t: Double      // seconds from test start
    let volts: Double
}

struct CrankResult {
    let rest: Double
    let crankMin: Double
    let running: Double?

    var restVerdict: String {
        rest >= 12.6 ? "Fully charged" : rest >= 12.4 ? "OK (about 75 %)" : rest >= 12.2 ? "Low (about 50 %) — charge it" : "Discharged — charge and load-test"
    }
    var crankVerdict: String {
        crankMin >= 10.0 ? "Strong" : crankMin >= 9.6 ? "Acceptable" : "Weak — battery or starter/cables are struggling"
    }
    var runningVerdict: String {
        guard let r = running else { return "Engine didn't start during the test" }
        return (13.4...14.8).contains(r) ? "Charging normally" : r < 13.4 ? "Charging low — check alternator/belt" : "Charging high — check regulator"
    }
}

// MARK: - PDF export

enum PDFExporter {
    /// Renders the Markdown report to a paginated US-Letter PDF.
    @MainActor
    static func write(markdown: String, to url: URL) throws {
        let html = htmlDocument(from: markdown)
        guard let data = html.data(using: .utf8),
              let text = NSAttributedString(html: data, options: [
                  .documentType: NSAttributedString.DocumentType.html,
                  .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        else { throw CocoaError(.fileWriteUnknown) }

        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 44; info.rightMargin = 44
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        if let lm = view.layoutManager, let tc = view.textContainer {
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height
            view.frame = NSRect(x: 0, y: 0, width: width, height: max(h + 20, 100))
        }

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Tiny Markdown → HTML for the report's own format (headings, bullets, bold).
    static func htmlDocument(from md: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func inline(_ s: String) -> String {
            var out = esc(s)
            while let r = out.range(of: "**"), let r2 = out.range(of: "**", range: r.upperBound..<out.endIndex) {
                let inner = out[r.upperBound..<r2.lowerBound]
                out.replaceSubrange(r.lowerBound..<r2.upperBound, with: "<b>\(inner)</b>")
            }
            return out
        }
        var body = ""
        var listDepth = 0
        func setDepth(_ d: Int) {
            while listDepth < d { body += "<ul>"; listDepth += 1 }
            while listDepth > d { body += "</ul>"; listDepth -= 1 }
        }
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("    - ") { setDepth(2); body += "<li>\(inline(String(line.dropFirst(6))))</li>" }
            else if line.hasPrefix("- ") { setDepth(1); body += "<li>\(inline(String(line.dropFirst(2))))</li>" }
            else {
                setDepth(0)
                if line.hasPrefix("## ") { body += "<h2>\(inline(String(line.dropFirst(3))))</h2>" }
                else if line.hasPrefix("# ") { body += "<h1>\(inline(String(line.dropFirst(2))))</h1>" }
                else if !line.trimmingCharacters(in: .whitespaces).isEmpty { body += "<p>\(inline(line))</p>" }
            }
        }
        setDepth(0)
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica; font-size: 10.5pt; color: #222; }
        h1 { font-size: 20pt; margin-bottom: 2pt; } h2 { font-size: 13pt; margin-top: 14pt; color: #333; border-bottom: 1px solid #ccc; }
        li { margin-bottom: 2pt; } p { margin: 2pt 0; }
        </style></head><body>\(body)</body></html>
        """
    }
}

// MARK: - AI explanation (Claude API)

enum AIExplainer {
    static let models = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-4-5-20251001"]

    private static let system = """
    You are an experienced, honest automotive diagnostic technician. The user will paste a scan report \
    from a generic OBD-II reader. Explain it to the car's owner in plain English:
    1. The most likely problem(s), in order of likelihood, and why the data points there.
    2. How urgent it is — safe to drive, drive gently, or stop.
    3. What to check first (cheapest/most likely first), and what to ask a repair shop.
    4. Anything that looks normal and can be ignored.
    Be clear about uncertainty. Generic OBD-II only sees emissions-related data, so say when a dealer-level \
    scan is needed. Keep it under 400 words. Use short headings and bullet points.
    """

    static func explain(report: String, apiKey: String, model: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "system": system,
            "messages": [["role": "user", "content": report]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "AIExplainer", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let blocks = json?["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        guard !text.isEmpty else {
            throw NSError(domain: "AIExplainer", code: 0, userInfo: [NSLocalizedDescriptionKey: "Empty response"])
        }
        return text
    }
}

/// Stores the API key in the macOS Keychain rather than in plain preferences.
enum Keychain {
    private static let service = "OBDReader"
    private static let account = "anthropic-api-key"

    static func load() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

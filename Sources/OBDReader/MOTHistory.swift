import Foundation
import Security
import SwiftUI
import Charts

// MARK: - UK MOT history (DVSA MOT History API)
//
// Access is free but needs registration; DVSA emails a client ID, client secret, API key and the
// token URL. Auth: OAuth 2.0 client credentials (scope https://tapi.dvsa.gov.uk/.default), then
// requests carry "Authorization: Bearer <token>" and "X-API-Key: <key>".
// Endpoints: https://history.mot.api.gov.uk/v1/trade/vehicles/registration/{reg} and …/vin/{vin}.
// Field names follow DVSA's published file format (motTests, completedDate, odometerValue…).

enum SecretStore {
    private static let service = "OBDReader"
    static func load(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    static func save(_ value: String, _ account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct MOTDefect: Identifiable {
    let id = UUID()
    let type: String
    let text: String
    let dangerous: Bool
}

struct MOTTest: Identifiable {
    let id = UUID()
    let completed: String
    let date: Date?
    let result: String
    let odometer: Double?
    let unit: String
    let odometerType: String
    let expiry: String
    let defects: [MOTDefect]

    /// Odometer in km (nil when not read).
    var odometerKm: Double? {
        guard let o = odometer else { return nil }
        return unit.lowercased().hasPrefix("mi") ? o / 0.621371 : o
    }
}

struct MOTVehicle {
    var registration = ""
    var make = ""
    var model = ""
    var firstUsed = ""
    var fuel = ""
    var colour = ""
    var tests: [MOTTest] = []

    /// Places where the recorded mileage went down between two MOTs.
    var mileageDrops: [(earlier: MOTTest, later: MOTTest)] {
        let read = tests.filter { $0.odometerKm != nil && $0.date != nil }.sorted { $0.date! < $1.date! }
        var out: [(MOTTest, MOTTest)] = []
        for i in 1..<max(read.count, 1) where read[i].odometerKm! + 1 < read[i - 1].odometerKm! {
            out.append((read[i - 1], read[i]))
        }
        return out.map { (earlier: $0.0, later: $0.1) }
    }
}

enum MOTHistoryError: LocalizedError {
    case missingCredentials, http(Int, String), badResponse
    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Add the MOT History API credentials DVSA emailed you."
        case .http(let c, let body): return "MOT History API returned \(c)\(body.isEmpty ? "" : ": \(body.prefix(200))")"
        case .badResponse: return "Unexpected reply from the MOT History API."
        }
    }
}

enum MOTHistoryService {
    static let baseURL = "https://history.mot.api.gov.uk/v1/trade/vehicles"
    static let defaultTokenURL = "https://login.microsoftonline.com/a455b827-244f-4c97-b5b4-ce5d13b4d00c/oauth2/v2.0/token"
    static let scope = "https://tapi.dvsa.gov.uk/.default"

    static var clientID: String { SecretStore.load("mot-client-id") }
    static var clientSecret: String { SecretStore.load("mot-client-secret") }
    static var apiKey: String { SecretStore.load("mot-api-key") }
    static var tokenURL: String { let t = SecretStore.load("mot-token-url"); return t.isEmpty ? defaultTokenURL : t }
    static var hasCredentials: Bool { !clientID.isEmpty && !clientSecret.isEmpty && !apiKey.isEmpty }

    private static var cachedToken: (value: String, expires: Date)?

    private static func token() async throws -> String {
        if let t = cachedToken, t.expires > Date().addingTimeInterval(60) { return t.value }
        guard hasCredentials, let url = URL(string: tokenURL) else { throw MOTHistoryError.missingCredentials }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        req.httpBody = Data("grant_type=client_credentials&client_id=\(enc(clientID))&client_secret=\(enc(clientSecret))&scope=\(enc(scope))".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = obj["access_token"] as? String else {
            throw MOTHistoryError.http(code, String(decoding: data, as: UTF8.self))
        }
        let secs = (obj["expires_in"] as? Double) ?? Double((obj["expires_in"] as? String) ?? "") ?? 3600
        cachedToken = (tok, Date().addingTimeInterval(secs))
        return tok
    }

    /// Look up by number plate (spaces removed) or by VIN.
    static func lookup(registration: String? = nil, vin: String? = nil) async throws -> MOTVehicle {
        let path: String
        if let reg = registration?.uppercased().filter({ $0.isLetter || $0.isNumber }), !reg.isEmpty {
            path = "/registration/" + reg
        } else if let vin, !vin.isEmpty {
            path = "/vin/" + vin.uppercased()
        } else { throw MOTHistoryError.badResponse }
        guard let url = URL(string: baseURL + path) else { throw MOTHistoryError.badResponse }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw MOTHistoryError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MOTHistoryError.badResponse }
        return parse(json)
    }

    static func parse(_ v: [String: Any]) -> MOTVehicle {
        func s(_ d: [String: Any], _ k: String) -> String {
            if let x = d[k] as? String { return x }
            if let x = d[k] as? NSNumber { return x.stringValue }
            return ""
        }
        let iso = ISO8601DateFormatter()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        var out = MOTVehicle(registration: s(v, "registration"), make: s(v, "make"), model: s(v, "model"),
                             firstUsed: s(v, "firstUsedDate"), fuel: s(v, "fuelType"), colour: s(v, "primaryColour"))
        let tests = (v["motTests"] as? [[String: Any]]) ?? []
        out.tests = tests.map { t in
            let completed = s(t, "completedDate")
            let date = iso.date(from: completed) ?? day.date(from: String(completed.prefix(10)))
            let defects = ((t["defects"] as? [[String: Any]]) ?? []).map {
                MOTDefect(type: s($0, "type"), text: s($0, "text"), dangerous: ($0["dangerous"] as? Bool) ?? false)
            }
            return MOTTest(completed: completed, date: date, result: s(t, "testResult"),
                           odometer: Double(s(t, "odometerValue")), unit: s(t, "odometerUnit"),
                           odometerType: s(t, "odometerResultType"), expiry: s(t, "expiryDate"), defects: defects)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return out
    }
}

// MARK: - View

struct MOTHistorySection: View {
    @EnvironmentObject var s: VehicleSession
    @State private var vehicle: MOTVehicle?
    @State private var error: String?
    @State private var loading = false
    @State private var editingCreds = false
    @State private var clientID = ""
    @State private var secret = ""
    @State private var apiKey = ""
    @State private var tokenURL = ""
    @State private var reg = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("UK MOT history").bold()
                Spacer()
                Button(MOTHistoryService.hasCredentials ? "API credentials…" : "Add API credentials…") {
                    clientID = MOTHistoryService.clientID; apiKey = MOTHistoryService.apiKey
                    tokenURL = MOTHistoryService.tokenURL; secret = ""
                    editingCreds.toggle()
                }
            }
            if editingCreds {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste what DVSA emailed you. Stored in the Mac's Keychain.").font(.caption).foregroundStyle(.secondary)
                    TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
                    SecureField(MOTHistoryService.clientSecret.isEmpty ? "Client secret" : "Client secret (saved — leave blank to keep)", text: $secret)
                        .textFieldStyle(.roundedBorder)
                    TextField("API key", text: $apiKey).textFieldStyle(.roundedBorder)
                    TextField("Token URL", text: $tokenURL).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save") {
                            SecretStore.save(clientID.trimmingCharacters(in: .whitespaces), "mot-client-id")
                            if !secret.isEmpty { SecretStore.save(secret.trimmingCharacters(in: .whitespaces), "mot-client-secret") }
                            SecretStore.save(apiKey.trimmingCharacters(in: .whitespaces), "mot-api-key")
                            SecretStore.save(tokenURL.trimmingCharacters(in: .whitespaces), "mot-token-url")
                            editingCreds = false
                        }
                        Button("Cancel") { editingCreds = false }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            HStack {
                TextField("Number plate", text: $reg).textFieldStyle(.roundedBorder).frame(width: 160)
                Button(loading ? "Fetching…" : "Fetch MOT history") { fetch() }
                    .disabled(loading || !MOTHistoryService.hasCredentials || (reg.isEmpty && s.vin.isEmpty))
                Text(reg.isEmpty ? "(or leave blank to use the car's VIN)" : "").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            if let v = vehicle { results(v) }
        }
        .onAppear { if reg.isEmpty { reg = s.profile?.registration ?? "" } }
    }

    private func fetch() {
        Task {
            loading = true; error = nil
            defer { loading = false }
            do {
                vehicle = try await MOTHistoryService.lookup(registration: reg.isEmpty ? nil : reg, vin: s.vin)
                if !reg.isEmpty, var p = s.profile, p.registration != reg {
                    p.registration = reg
                    s.saveProfile(p)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func results(_ v: MOTVehicle) -> some View {
        Text("\(v.registration) · \(v.make) \(v.model)\(v.firstUsed.isEmpty ? "" : " · first used \(v.firstUsed)")")
            .font(.callout)
        let drops = v.mileageDrops
        if !drops.isEmpty {
            ForEach(Array(drops.enumerated()), id: \.offset) { _, d in
                Label("Mileage went down: \(fmt(d.earlier)) on \(d.earlier.completed.prefix(10)), then \(fmt(d.later)) on \(d.later.completed.prefix(10)).",
                      systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
        }
        if let ecu = s.liveValues[0xA6],
           let last = v.tests.first(where: { $0.odometerKm != nil }), let lastKm = last.odometerKm, ecu + 1 < lastKm {
            Label("The engine computer's odometer (\(UnitKind.distance.format(ecu, s.units))) is below the last MOT reading (\(fmt(last))).",
                  systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
        let pts = v.tests.compactMap { t -> (Date, Double)? in
            guard let d = t.date, let km = t.odometerKm else { return nil }
            return (d, UnitKind.distance.present(km, s.units).0)
        }
        if pts.count >= 2 {
            Chart(pts.indices, id: \.self) { i in
                LineMark(x: .value("Date", pts[i].0), y: .value("Mileage", pts[i].1))
                PointMark(x: .value("Date", pts[i].0), y: .value("Mileage", pts[i].1))
            }
            .chartYAxisLabel(UnitKind.distance.present(0, s.units).1)
            .frame(height: 140)
        }
        ForEach(v.tests) { t in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(String(t.completed.prefix(10))).monospacedDigit()
                    Text(t.result.isEmpty ? "—" : t.result).bold()
                        .foregroundStyle(t.result.uppercased() == "PASSED" ? Color.green : Color.red)
                    Text(fmt(t)).monospacedDigit()
                    Spacer()
                    if !t.expiry.isEmpty { Text("expires \(t.expiry.prefix(10))").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(t.defects) { d in
                    Text("\(d.type.capitalized)\(d.dangerous ? " (dangerous)" : ""): \(d.text)")
                        .font(.caption).foregroundStyle(d.type.uppercased() == "ADVISORY" ? Color.secondary : Color.orange)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func fmt(_ t: MOTTest) -> String {
        guard let o = t.odometer else { return "no odometer reading" }
        return String(format: "%.0f %@", o, t.unit.lowercased().hasPrefix("mi") ? "mi" : "km")
    }
}

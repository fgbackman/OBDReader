import SwiftUI
import MapKit
import CoreLocation

// Nearby mechanics and licensing offices.
//
// Places come from Apple Maps (MKLocalSearch, free, no key) or, if the user adds their own key,
// Google Places API (New) Text Search, which also returns star ratings.
// No public API or dataset lists shops' hourly labour rates, so the rate column is what the
// user enters from a quote; it's saved on this Mac.

struct NearbyPlace: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
    let lat: Double
    let lon: Double
    let phone: String?
    let website: URL?
    let mapURL: URL?
    var rating: Double?
    var ratingCount: Int?
    var meters: Double

    var rateKey: String { (name + "|" + address).lowercased() }
}

enum PlaceSource: String, CaseIterable, Identifiable {
    case apple = "Apple Maps (free)"
    case google = "Google (adds ratings; your API key)"
    var id: String { rawValue }
}

enum NearbyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

enum NearbySearch {
    static func locate(_ place: String) async throws -> CLLocation {
        let marks = try await CLGeocoder().geocodeAddressString(place)
        guard let loc = marks.first?.location else { throw NearbyError.message("Couldn't find \"\(place)\".") }
        return loc
    }

    static func apple(_ query: String, near c: CLLocation, radius: Double) async throws -> [NearbyPlace] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.resultTypes = .pointOfInterest
        req.region = MKCoordinateRegion(center: c.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        let resp = try await MKLocalSearch(request: req).start()
        return resp.mapItems.compactMap { item -> NearbyPlace? in
            let co = item.placemark.coordinate
            let here = CLLocation(latitude: co.latitude, longitude: co.longitude)
            let name = item.name ?? "Unnamed"
            var comps = URLComponents(string: "https://maps.apple.com/")!
            comps.queryItems = [URLQueryItem(name: "q", value: name),
                                URLQueryItem(name: "ll", value: "\(co.latitude),\(co.longitude)")]
            return NearbyPlace(id: "\(name)|\(co.latitude),\(co.longitude)", name: name,
                               address: item.placemark.title ?? "", lat: co.latitude, lon: co.longitude,
                               phone: item.phoneNumber, website: item.url, mapURL: comps.url,
                               meters: here.distance(from: c))
        }
        .filter { $0.meters <= radius * 1.5 }
    }

    /// Google Places API (New) Text Search. Rating fields are billed at Google's Enterprise tier.
    static func google(_ query: String, near c: CLLocation, radius: Double, key: String) async throws -> [NearbyPlace] {
        var req = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchText")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("places.id,places.displayName,places.formattedAddress,places.location,places.rating,places.userRatingCount,places.nationalPhoneNumber,places.websiteUri,places.googleMapsUri",
                     forHTTPHeaderField: "X-Goog-FieldMask")
        let body: [String: Any] = [
            "textQuery": query,
            "pageSize": 20,
            "locationBias": ["circle": ["center": ["latitude": c.coordinate.latitude, "longitude": c.coordinate.longitude],
                                        "radius": min(radius, 50000)]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw NearbyError.message("Google: \(msg)")
        }
        let places = json["places"] as? [[String: Any]] ?? []
        return places.compactMap { p -> NearbyPlace? in
            guard let loc = p["location"] as? [String: Any],
                  let lat = loc["latitude"] as? Double, let lon = loc["longitude"] as? Double else { return nil }
            let name = ((p["displayName"] as? [String: Any])?["text"] as? String) ?? "Unnamed"
            return NearbyPlace(id: p["id"] as? String ?? "\(name)|\(lat),\(lon)", name: name,
                               address: p["formattedAddress"] as? String ?? "", lat: lat, lon: lon,
                               phone: p["nationalPhoneNumber"] as? String,
                               website: (p["websiteUri"] as? String).flatMap(URL.init(string:)),
                               mapURL: (p["googleMapsUri"] as? String).flatMap(URL.init(string:)),
                               rating: p["rating"] as? Double,
                               ratingCount: p["userRatingCount"] as? Int,
                               meters: CLLocation(latitude: lat, longitude: lon).distance(from: c))
        }
    }
}

/// Labour rates the user was quoted, per shop. Saved in UserDefaults on this Mac.
final class ShopRates: ObservableObject {
    static let shared = ShopRates()
    @Published private(set) var rates: [String: Double]
    private init() {
        rates = (UserDefaults.standard.dictionary(forKey: "shopRates") as? [String: Double]) ?? [:]
    }
    func set(_ v: Double?, for key: String) {
        rates[key] = v
        UserDefaults.standard.set(rates, forKey: "shopRates")
    }
}

// MARK: - Page

struct NearbyView: View {
    @EnvironmentObject var s: VehicleSession
    @ObservedObject private var rates = ShopRates.shared

    enum Tab: String, CaseIterable, Identifiable { case shops = "Mechanics", offices = "DMV / licensing"; var id: String { rawValue } }
    enum Sort: String, CaseIterable, Identifiable { case rate = "Labour rate", rating = "Rating", distance = "Distance"; var id: String { rawValue } }

    @AppStorage("nearbyPlace") private var place = ""
    @AppStorage("nearbyRadiusMiles") private var radiusMiles = 15.0
    @AppStorage("nearbySource") private var sourceRaw = PlaceSource.apple.rawValue
    @AppStorage("nearbyRegion") private var regionChoice = ""
    @State private var tab = Tab.shops
    @State private var sort = Sort.rating
    @State private var query = "auto repair"
    @State private var googleKey = SecretStore.load("google-places-key")
    @State private var center: CLLocation?
    @State private var shops: [NearbyPlace] = []
    @State private var offices: [OfficeGroup] = []
    @State private var searching = false
    @State private var error: String?

    private var source: PlaceSource { PlaceSource(rawValue: sourceRaw) ?? .apple }
    private var region: String { regionChoice.isEmpty ? (s.profile?.region ?? "California") : regionChoice }
    private var isUK: Bool { region == CarProfile.regionUK }
    private var currency: String { isUK ? "£" : "$" }
    private var radiusMeters: Double { radiusMiles * 1609.344 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Nearby",
                           subtitle: "Mechanics sorted by rate, rating or distance — and where to go for registration and licensing")
                searchCard
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                if let e = error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if tab == .shops { shopsSection } else { officesSection }
            }
            .padding(24)
        }
        .onChange(of: regionChoice) { _, _ in offices = [] }
        .onChange(of: place) { _, _ in offices = []; shops = [] }
        .onAppear { if place.isEmpty, let r = s.profile?.region, r == CarProfile.regionUK { query = "garage MOT" } }
    }

    // MARK: Search settings

    private var searchCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField(isUK ? "Town or postcode" : "City or ZIP code", text: $place)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                        .onSubmit { Task { await run() } }
                    Picker("Within", selection: $radiusMiles) {
                        ForEach([5.0, 10, 15, 25, 30], id: \.self) { Text("\(Int($0)) mi").tag($0) }
                    }.frame(width: 130)
                    Picker("Rules", selection: $regionChoice) {
                        Text("Car's region (\(s.profile?.region ?? "California"))").tag("")
                        ForEach(CarProfile.regions, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 280)
                }
                HStack {
                    Picker("Source", selection: $sourceRaw) {
                        ForEach(PlaceSource.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.frame(width: 340)
                    if source == .google {
                        SecureField("Google Places API key", text: $googleKey)
                            .textFieldStyle(.roundedBorder).frame(width: 240)
                        Button("Save key") { SecretStore.save(googleKey.trimmingCharacters(in: .whitespaces), "google-places-key") }
                    }
                }
                if source == .google {
                    Text("Uses Google Places API (New) Text Search. Star ratings are billed at Google's Enterprise rate on your own Cloud account. The key is kept in your Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Apple Maps is free and needs no key, but it doesn't give star ratings. Switch to Google for ratings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Mechanics

    private var shopQuickQueries: [String] {
        var q = ["auto repair", "European car specialist", "exotic car service", "auto electrician", "automotive locksmith"]
        if region == "California" { q.append("smog check station") }
        if isUK { q = ["garage MOT", "European car specialist", "exotic car service", "MOT test centre", "auto locksmith"] }
        return q
    }

    private var sortedShops: [NearbyPlace] {
        switch sort {
        case .distance: return shops.sorted { $0.meters < $1.meters }
        case .rating:
            return shops.sorted { a, b in
                switch (a.rating, b.rating) {
                case let (x?, y?): return x != y ? x > y : (a.ratingCount ?? 0) > (b.ratingCount ?? 0)
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.meters < b.meters
                }
            }
        case .rate:
            return shops.sorted { a, b in
                switch (rates.rates[a.rateKey], rates.rates[b.rateKey]) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.meters < b.meters
                }
            }
        }
    }

    private var shopsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("What to search for", text: $query).textFieldStyle(.roundedBorder).frame(width: 240)
                    .onSubmit { Task { await run() } }
                Button(searching ? "Searching…" : "Search") { Task { await run() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(searching || place.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Picker("Sort by", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                    .frame(width: 200)
            }
            HStack {
                ForEach(shopQuickQueries, id: \.self) { q in
                    Button(q) { query = q; Task { await run() } }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            Text("Labour rates aren't published in any public database or API, so type in the hourly rate each shop quotes you. It's saved on this Mac and used for sorting. Ask whether the rate differs for diagnosis and for exotic or European cars.")
                .font(.caption).foregroundStyle(.secondary)
            if region == "Florida" {
                Text("Florida: repair shops must be registered with FDACS, and you're entitled to a written estimate for jobs over $150 (Fla. Stat. 559.904, 559.905).")
                    .font(.caption).foregroundStyle(.secondary)
            } else if region == "California" {
                Text("California: shops that repair or diagnose cars for pay must be registered with the Bureau of Automotive Repair — check the licence at bar.ca.gov.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if source == .apple && sort == .rating && !shops.isEmpty {
                Text("Apple Maps results have no ratings — switch the source to Google to sort by rating.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(sortedShops) { p in PlaceRow(place: p, currency: currency, showRate: true) }
            if !searching && shops.isEmpty && center != nil {
                Text("No shops found. Try a wider radius or another search term.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Offices

    private var officesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(searching ? "Searching…" : "Find nearest offices") { Task { await runOffices() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(searching || place.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            Card { officeInfo }
            ForEach(offices) { group in
                Text(group.title).font(.headline).padding(.top, 4)
                if group.places.isEmpty {
                    Text("None found within \(Int(radiusMiles)) miles.").foregroundStyle(.secondary)
                }
                ForEach(Array(group.places.sorted { $0.meters < $1.meters }.prefix(6))) { PlaceRow(place: $0, currency: currency, showRate: false) }
            }
        }
    }

    @ViewBuilder private var officeInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch region {
            case "California":
                Text("California DMV").font(.headline)
                Text("Field offices handle titles, registration and licences. Some services, such as registration renewal and replacement licences, have no counter service and must be done online, at a kiosk or by mail.")
                Link("DMV office locations", destination: URL(string: "https://www.dmv.ca.gov/portal/locations/")!)
                Link("Book a DMV appointment", destination: URL(string: "https://www.dmv.ca.gov/portal/appointments/")!)
            case "Florida":
                Text("Florida — county tax collector offices").font(.headline)
                Text("In Florida, driver licence and motor vehicle services (title, registration, plates) are handled at service centres run by each county's tax collector. FLHSMV lists them by county.")
                Link("FLHSMV service locations by county", destination: URL(string: "https://www.flhsmv.gov/locations/")!)
            case CarProfile.regionUK:
                Text("UK — DVLA has no public offices").font(.headline)
                Text("All DVLA local offices in England, Wales and Scotland closed in December 2013, and DVLA's Swansea site has no public counter. Most things are done online. Post Office branches can tax a vehicle, renew a 10-year photocard licence, make a SORN, and apply for a replacement V5C logbook. MOTs are done at approved test centres (blue sign with three white triangles).")
                Link("Contact DVLA", destination: URL(string: "https://www.gov.uk/contact-the-dvla")!)
                Link("DVLA local office closures (GOV.UK, 2013)", destination: URL(string: "https://www.gov.uk/government/news/dvla-local-office-closures")!)
                Link("Post Office branch finder", destination: URL(string: "https://www.postoffice.co.uk/branch-finder")!)
                Link("Post Office vehicle tax services", destination: URL(string: "https://www.postoffice.co.uk/identity/vehicle-tax")!)
                Link("DVSA list of every active MOT test station (CSV)", destination: URL(string: "https://www.gov.uk/government/publications/active-mot-test-stations")!)
                Link("Check MOT history", destination: URL(string: "https://www.gov.uk/check-mot-history")!)
            default:
                Text("Motor vehicle office").font(.headline)
                Text("Each US state runs its own DMV (some call it BMV, MVD or the tax office). Search below, and check your state's DMV website for appointments.")
            }
        }
        .font(.callout)
    }

    private var officeQueries: [(title: String, query: String)] {
        switch region {
        case "California": return [("Nearest DMV field offices", "DMV office")]
        case "Florida": return [("Nearest tax collector offices (DMV services)", "tax collector office"),
                                ("Driver licence / motor vehicle service centres", "driver license office")]
        case CarProfile.regionUK: return [("Nearest Post Office branches", "Post Office"),
                                          ("Nearest MOT test centres", "MOT test centre")]
        default: return [("Nearest DMV offices", "DMV")]
        }
    }

    // MARK: Actions

    private func ensureCenter() async throws -> CLLocation {
        let c = try await NearbySearch.locate(place)
        center = c
        return c
    }

    private func search(_ q: String, near c: CLLocation) async throws -> [NearbyPlace] {
        if source == .google {
            let key = googleKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw NearbyError.message("Add a Google Places API key, or switch the source to Apple Maps.") }
            return try await NearbySearch.google(q, near: c, radius: radiusMeters, key: key)
                .filter { $0.meters <= radiusMeters * 1.5 }
        }
        return try await NearbySearch.apple(q, near: c, radius: radiusMeters)
    }

    private func run() async {
        guard !searching else { return }
        searching = true; error = nil
        defer { searching = false }
        do {
            let c = try await ensureCenter()
            shops = try await search(query, near: c)
            if source == .apple && sort == .rating { sort = .distance }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runOffices() async {
        guard !searching else { return }
        searching = true; error = nil
        defer { searching = false }
        do {
            let c = try await ensureCenter()
            var out: [OfficeGroup] = []
            for q in officeQueries {
                out.append(OfficeGroup(title: q.title, places: try await search(q.query, near: c)))
            }
            offices = out
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct OfficeGroup: Identifiable {
    let title: String
    let places: [NearbyPlace]
    var id: String { title }
}

struct PlaceRow: View {
    let place: NearbyPlace
    let currency: String
    let showRate: Bool
    @ObservedObject private var rates = ShopRates.shared
    @State private var rateText = ""
    @FocusState private var editing: Bool

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(place.name).font(.headline)
                        if let r = place.rating {
                            Text(String(format: "%.1f ★", r)).font(.callout.bold()).foregroundStyle(.orange)
                            if let n = place.ratingCount { Text("(\(n))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Text(place.address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Text(String(format: "%.1f mi", place.meters / 1609.344)).font(.caption.monospacedDigit())
                        if let ph = place.phone { Text(ph).font(.caption).textSelection(.enabled) }
                        if let w = place.website { Link("Website", destination: w).font(.caption) }
                        if let m = place.mapURL { Link("Map", destination: m).font(.caption) }
                    }
                }
                Spacer()
                if showRate {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(currency)
                            TextField("rate", text: $rateText)
                                .textFieldStyle(.roundedBorder).frame(width: 70)
                                .focused($editing)
                                .onSubmit(saveRate)
                            Text("/h")
                        }
                        Text("quoted rate").font(.caption2).foregroundStyle(.secondary)
                    }
                    .onAppear { rateText = rates.rates[place.rateKey].map { String(format: "%g", $0) } ?? "" }
                    .onChange(of: editing) { _, now in if !now { saveRate() } }
                }
            }
        }
    }

    private func saveRate() {
        let t = rateText.filter { $0.isNumber || $0 == "." }
        rates.set(Double(t), for: place.rateKey)
    }
}

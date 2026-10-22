import Foundation

/// One module to talk to: request address, optional extended-address byte, optional reply address.
/// Written as a spec string: "7E0", "713>77D", "6F1/12>612", "18DA10F1", "18DA10F1>18DAF110".
struct ModuleTarget: Hashable {
    let request: String     // 3 hex (11-bit) or 8 hex (29-bit)
    let ext: String?        // 2 hex, extended addressing (BMW 6F1, Toyota 750)
    let reply: String?      // explicit reply address; nil = standard rule

    init(request: String, ext: String? = nil, reply: String? = nil) {
        self.request = request; self.ext = ext; self.reply = reply
    }

    init?(spec: String) {
        let s = spec.uppercased().filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ">", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }
        let left = parts[0].split(whereSeparator: { $0 == "/" || $0 == ":" }).map(String.init)
        guard (1...2).contains(left.count) else { return nil }
        let req = left[0]
        guard [3, 8].contains(req.count), isHex(req) else { return nil }
        var e: String?
        if left.count == 2 {
            guard left[1].count == 2, isHex(left[1]), req.count == 3 else { return nil }
            e = left[1]
        }
        var r: String?
        if parts.count == 2 {
            guard parts[1].count == req.count, isHex(parts[1]) else { return nil }
            r = parts[1]
        }
        self.init(request: req, ext: e, reply: r)
    }

    var is29Bit: Bool { request.count == 8 }

    var spec: String {
        var s = request
        if let e = ext { s += "/" + e }
        if let r = reply { s += ">" + r }
        return s
    }

    /// Where the answer comes back. 11-bit: request + 8 unless stated. 29-bit "18DAttF1" → "18DAF1tt".
    var replyAddress: String? {
        if let r = reply { return r }
        if is29Bit {
            guard request.hasPrefix("18DA"), request.hasSuffix("F1") else { return nil }
            let t = request.dropFirst(4).prefix(2)
            return "18DAF1" + t
        }
        guard let v = Int(request, radix: 16), v + 8 <= 0x7FF else { return nil }
        return String(format: "%03X", v + 8)
    }

    /// The reply address as the parser reports it (29-bit: last two hex digits).
    var replyKey: String? {
        guard let r = replyAddress else { return nil }
        return is29Bit ? String(r.suffix(2)) : r
    }
}

struct ModulePresetEntry: Identifiable, Hashable {
    let spec: String
    let name: String
    var id: String { spec }
    var target: ModuleTarget { ModuleTarget(spec: spec)! }
}

/// Brand module address lists. Every row comes from a public source checked in October 2026:
/// opendbc (github.com/commaai/opendbc, car/<brand>/values.py & fingerprints.py),
/// OBDb (github.com/OBDb/<Make-Model>, signalsets/v3/default.json),
/// OVMS (vweup_obd.h), the FORScan forum and ISO 15765-4:2005.
/// Not every car of a brand has every module; silent addresses are normal.
struct ModulePreset: Identifiable, Hashable {
    let brand: String
    let note: String
    let entries: [ModulePresetEntry]
    var id: String { brand }

    static func e(_ spec: String, _ name: String) -> ModulePresetEntry { ModulePresetEntry(spec: spec, name: name) }

    static let all: [ModulePreset] = [
        ModulePreset(brand: "VW / Audi / Porsche / Bentley (VAG)",
                     note: "VAG modules reply at request + 0x6A (713→77D). Sources: OVMS vweup_obd.h, opendbc volkswagen, OBDb VW-Jetta / Porsche-Taycan / Bentley-Bentayga. Bugatti isn't in any public list; it may follow this scheme, but that's unconfirmed.",
                     entries: [e("7E0", "Engine (01)"), e("7E1", "Transmission (02)"), e("713>77D", "Brakes / ABS (03)"),
                               e("714>77E", "Instrument cluster (17)"), e("715>77F", "Airbag (15)"), e("710>77A", "Gateway (19)"),
                               e("712>77C", "Steering (44)"), e("757>7C1", "Radar"), e("74F>7B9", "Front camera")]),
        ModulePreset(brand: "Toyota / Lexus",
                     note: "Engine and transmission are combined on some models. 750/xx modules use extended addressing (experimental — needs an adapter that supports AT CEA). Sources: opendbc toyota, OBDb Toyota-Prius / RAV4.",
                     entries: [e("7E0", "Engine"), e("700", "Engine (alt.)"), e("7E1", "Transmission"), e("701", "Transmission (alt.)"),
                               e("7E2", "Hybrid control (older)"), e("7D2", "Hybrid control (UDS)"), e("7E3", "Hybrid battery (Prius)"),
                               e("7B0", "ABS"), e("7A1", "Power steering"), e("780", "Airbag"), e("791", "Driver support unit"),
                               e("7C0", "Instrument cluster"), e("7C4", "Climate"),
                               e("750/0F>758", "Radar"), e("750/6D>758", "Front camera"), e("750/2A>758", "Tyre pressure"),
                               e("750/40>758", "Body"), e("750/5F>758", "Central gateway")]),
        ModulePreset(brand: "GM (Chevrolet, GMC, Cadillac, Buick)",
                     note: "Body modules reply at request + 0x400 (241→641). Some trucks also use 29-bit addresses whose reply format isn't confirmed, so they're left out. Sources: OBDb Chevrolet-Silverado-1500 / Bolt-EV / Corvette, opendbc gm.",
                     entries: [e("7E0", "Engine"), e("7E2", "Transmission"), e("7E1", "Transmission (Corvette, Bolt)"),
                               e("7E7", "Battery (Bolt EV)"), e("241>641", "Body / tyre pressure"), e("24B>64B", "Front camera")]),
        ModulePreset(brand: "Ford / Lincoln",
                     note: "Ford's non-emissions modules are on 11-bit addresses, not 29-bit. Sources: opendbc ford, OBDb Ford-Explorer / F-150 / Ranger, FORScan forum (BCM 726). The cluster at 720 is likely but not named in a source.",
                     entries: [e("7E0", "Powertrain (PCM)"), e("7E1", "Transmission"), e("726", "Body (BCM)"), e("760", "ABS"),
                               e("730", "Power steering"), e("7D0", "Sync / APIM"), e("706", "Front camera"), e("764", "Radar"),
                               e("732", "Gear shift module"), e("720", "Instrument cluster (likely)")]),
        ModulePreset(brand: "Hyundai / Kia / Genesis",
                     note: "ABS is 7D1 (not 7E2). On EVs, 7E3–7E5 are motor / battery / charger. Sources: opendbc hyundai, OBDb Hyundai-Tucson / Kia-Niro / Kia-EV6.",
                     entries: [e("7E0", "Engine"), e("7E1", "Transmission"), e("7E2", "Hybrid control"), e("7E4", "Battery (EV / hybrid)"),
                               e("7D1", "ABS / ESC"), e("7D4", "Power steering"), e("7D0", "Radar"), e("7C4", "Front camera"),
                               e("7A0", "Body"), e("7C6", "Instrument cluster"), e("7B3", "Climate")]),
        ModulePreset(brand: "Stellantis (Chrysler, Dodge, Jeep, Ram, Fiat)",
                     note: "Older 11-bit modules reply at request − 0x280 (747→4C7). Newer models use 29-bit. The Secure Gateway on 2018+ cars allows reading; it blocks clearing and active tests. Sources: opendbc chrysler, OBDb Jeep-Wrangler / Ram-1500.",
                     entries: [e("7E0", "Engine"), e("7E1", "Transmission"), e("7E2", "Hybrid"), e("747>4C7", "ABS"),
                               e("744>4C4", "Airbag"), e("742>4C2", "Instrument cluster"), e("753>4D3", "Radar"), e("75A>4DA", "Power steering"),
                               e("18DA10F1", "Engine (29-bit)"), e("18DA18F1", "Transmission (29-bit)"), e("18DA28F1", "ABS (29-bit)"),
                               e("18DA30F1", "Power steering (29-bit)"), e("18DA40F1", "Body (29-bit)"), e("18DA60F1", "Cluster (29-bit)"),
                               e("18DAC0F1", "Airbag (29-bit)")]),
        ModulePreset(brand: "Honda / Acura",
                     note: "Honda modules are on 29-bit addresses. Source: opendbc honda.",
                     entries: [e("18DA10F1", "Engine (PGM-FI)"), e("18DA1EF1", "Transmission"), e("18DA28F1", "VSA / ABS"),
                               e("18DA30F1", "Power steering"), e("18DA53F1", "Airbag"), e("18DA60F1", "Instrument cluster"),
                               e("18DAEFF1", "Gateway")]),
        ModulePreset(brand: "Nissan / Infiniti",
                     note: "Chassis modules reply at request + 0x20 (740→760). Sources: opendbc nissan, OBDb Nissan-Leaf.",
                     entries: [e("7E0", "Engine"), e("740>760", "ABS"), e("742>762", "Power steering"), e("743>763", "Instrument cluster"),
                               e("707>727", "Front camera"), e("18DAD0F1", "Gateway (29-bit)")]),
        ModulePreset(brand: "Subaru",
                     note: "Sources: opendbc subaru, OBDb Subaru-Outback.",
                     entries: [e("7E0", "Engine"), e("7A2", "Engine (alt.)"), e("7E1", "Transmission"), e("7A3", "Transmission (alt.)"),
                               e("7B0", "ABS"), e("746", "Power steering"), e("787", "EyeSight camera")]),
        ModulePreset(brand: "Mazda",
                     note: "Source: opendbc mazda.",
                     entries: [e("7E0", "Engine"), e("7E1", "Transmission"), e("760", "ABS"), e("730", "Power steering"),
                               e("706", "Front camera"), e("764", "Radar")]),
        ModulePreset(brand: "BMW / MINI (experimental)",
                     note: "BMW uses extended addressing: requests on 6F1 with the module number as the first byte, replies on 600 + module. Needs an adapter that supports AT CEA (ELM327 v1.4+ or OBDLink). Only the engine (12) is named in a source; the others are labelled by the data seen there. Sources: OBDb BMW-3-Series / X5, projectgus.com.",
                     entries: [e("7E0", "Engine (emissions)"), e("6F1/12>612", "Engine (DME/DDE)"), e("6F1/18>618", "Module 18 (transmission data)"),
                               e("6F1/29>629", "Module 29 (DSC data)"), e("6F1/30>630", "Module 30 (steering data)"),
                               e("6F1/60>660", "Module 60 (cluster data)"), e("6F1/78>678", "Module 78 (climate data)")]),
    ]

    static func named(_ brand: String?) -> ModulePreset? { all.first { $0.brand == brand } }

    /// First guess from the make typed in the car profile.
    static func guess(make: String?) -> ModulePreset? {
        guard let m = make?.lowercased(), !m.isEmpty else { return nil }
        let map: [(String, [String])] = [
            ("VW / Audi / Porsche / Bentley (VAG)", ["volkswagen", "vw", "audi", "porsche", "bentley", "seat", "skoda", "lamborghini", "bugatti"]),
            ("Toyota / Lexus", ["toyota", "lexus", "scion"]),
            ("GM (Chevrolet, GMC, Cadillac, Buick)", ["chevrolet", "chevy", "gmc", "cadillac", "buick", "gm"]),
            ("Ford / Lincoln", ["ford", "lincoln"]),
            ("Hyundai / Kia / Genesis", ["hyundai", "kia", "genesis"]),
            ("Stellantis (Chrysler, Dodge, Jeep, Ram, Fiat)", ["chrysler", "dodge", "jeep", "ram", "fiat", "alfa"]),
            ("Honda / Acura", ["honda", "acura"]),
            ("Nissan / Infiniti", ["nissan", "infiniti"]),
            ("Subaru", ["subaru"]),
            ("Mazda", ["mazda"]),
            ("BMW / MINI (experimental)", ["bmw", "mini"]),
        ]
        return map.first { $0.1.contains { m.contains($0) } }.flatMap { named($0.0) }
    }

    /// Name for a spec in any preset (for labelling scan results).
    static func label(for spec: String, in preset: ModulePreset?) -> String? {
        preset?.entries.first { $0.spec == spec }?.name
    }
}

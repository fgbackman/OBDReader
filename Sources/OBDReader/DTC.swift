import Foundation

enum DTCKind: String {
    case stored = "Stored"        // Mode 03 – confirmed, usually lights the MIL
    case pending = "Pending"      // Mode 07 – seen once, not yet confirmed
    case permanent = "Permanent"  // Mode 0A – can't be cleared by a scan tool
}

struct DTC: Identifiable, Hashable {
    let code: String
    let kind: DTCKind
    let ecu: String
    var id: String { "\(kind.rawValue)-\(ecu)-\(code)" }

    var description: String { DTCDatabase.describe(code) }
    var causes: String? { DTCDatabase.causes(code) }
    var system: String { DTCDatabase.system(code) }
    var isManufacturerSpecific: Bool {
        let d = Array(code)
        guard d.count == 5 else { return false }
        switch d[0] {
        case "P": return d[1] == "1" || (d[1] == "3" && d[2] < "4")
        default: return d[1] == "1" || d[1] == "2"
        }
    }

    /// Two raw bytes (SAE J2012 encoding) → "P0301". Returns nil for 0x0000 padding.
    static func decode(_ hi: UInt8, _ lo: UInt8) -> String? {
        if hi == 0 && lo == 0 { return nil }
        let letter = ["P", "C", "B", "U"][Int(hi >> 6)]
        return letter + String((hi >> 4) & 0x03) + String(format: "%X%02X", Int(hi & 0x0F), Int(lo))
    }

    /// Parse a Mode 03 / 07 / 0A reply from every ECU that answered.
    static func parse(_ messages: [ECUMessage], kind: DTCKind) -> [DTC] {
        var out: [DTC] = []
        for m in messages {
            for frame in m.frames {
                // 43 / 47 / 4A replies only — a "7F" negative response is not a code list.
                guard let first = frame.first, first & 0xF0 == 0x40 else { continue }
                // CAN: [43, count, hi, lo, hi, lo…]   Legacy: [43, hi, lo, hi, lo, hi, lo]
                var body = Array(frame.dropFirst())
                if m.isCAN, !body.isEmpty { body.removeFirst() }
                var i = 0
                while i + 1 < body.count {
                    if let code = decode(body[i], body[i + 1]) {
                        out.append(DTC(code: code, kind: kind, ecu: m.ecu))
                    }
                    i += 2
                }
            }
        }
        // Same code reported by two ECUs → keep both; exact duplicates → drop.
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }
}

enum DTCDatabase {
    static func describe(_ code: String) -> String {
        if let d = known[code] { return d }
        if let d = patterned(code) { return d }
        return "No generic description — \(system(code)). Manufacturer-specific meaning; see service info."
    }

    static func system(_ code: String) -> String {
        let c = Array(code)
        guard c.count == 5 else { return "Unknown" }
        switch c[0] {
        case "P":
            if c[1] == "3" { return c[2] == "4" ? "Cylinder deactivation" : "Manufacturer-controlled powertrain" }
            switch c[2] {
            case "0", "1": return "Fuel & air metering"
            case "2": return "Fuel & air metering (injector circuit)"
            case "3": return "Ignition system / misfire"
            case "4": return "Auxiliary emission controls"
            case "5": return "Speed control, idle & auxiliary inputs"
            case "6": return "Computer & output circuits"
            case "7", "8", "9": return "Transmission"
            case "A", "B", "C": return c[1] == "0" ? "Hybrid / electric drive" : "Powertrain"
            default: return "Powertrain"
            }
        case "C": return "Chassis (brakes, steering, suspension)"
        case "B": return "Body (airbags, climate, lighting, seats)"
        case "U": return "Network / module communication"
        default: return "Unknown"
        }
    }

    /// Usual causes, in our own words — leads to check, not a diagnosis. nil when we don't have any.
    static func causes(_ code: String) -> String? {
        if let c = commonCauses[code] { return c }
        guard code.count == 5, code.hasPrefix("P0"), let n = Int(code.dropFirst()) else { return nil }
        switch n {
        case 201...212: return "Faulty injector, damaged injector wiring or connector, or an injector driver fault in the engine computer."
        case 301...312: return "Worn spark plug or failed ignition coil on that cylinder (swap the coil to another cylinder and see if the misfire follows), a leaking injector, a vacuum leak, or low compression."
        case 351...362: return "Failed ignition coil, damaged coil connector or wiring, or a poor engine ground."
        case 135, 141, 155, 161: return "O2 sensor heater element burned out (most common), a blown heater fuse, or damaged sensor wiring."
        case 130...134, 136...140, 150...154, 156...160: return "Aging or contaminated O2 sensor, damaged wiring, or an exhaust leak near the sensor."
        default: return nil
        }
    }

    static let commonCauses: [String: String] = [
        "P0010": "Camshaft adjuster (VVT) solenoid or its wiring; low, dirty or wrong-grade oil starving the adjuster.",
        "P0011": "Low or dirty oil, a sticking camshaft adjuster solenoid, or a stretched timing chain / worn tensioner.",
        "P0012": "Low or dirty oil, a sticking camshaft adjuster solenoid, or a stretched timing chain / worn tensioner.",
        "P0013": "Exhaust/intake camshaft B adjuster solenoid or its wiring; low or dirty oil.",
        "P0014": "Low or dirty oil, a sticking cam adjuster, or timing chain stretch.",
        "P0016": "Timing chain/belt stretched or jumped a tooth, worn tensioner, or a failing cam/crank sensor.",
        "P0101": "Dirty or failing MAF sensor, an air leak between the MAF and the throttle, or a clogged air filter.",
        "P0102": "MAF sensor unplugged or failed, or broken MAF wiring.",
        "P0113": "Intake air temperature sensor unplugged or failed, or an open circuit in its wiring.",
        "P0128": "Thermostat stuck open (most common), low coolant, or a coolant temperature sensor reading low.",
        "P0171": "Vacuum leak (intake hoses, PCV valve or hose), dirty MAF, weak fuel pump or clogged filter, or an exhaust leak ahead of the O2 sensor.",
        "P0174": "Vacuum leak, dirty MAF, low fuel pressure, or an exhaust leak ahead of the bank 2 O2 sensor.",
        "P0200": "Injector circuit fault — injector, wiring/connector, or the engine computer's injector driver.",
        "P0300": "Worn spark plugs or coils, vacuum leaks, low fuel pressure, or low compression. Check which cylinders misfire on the Health page.",
        "P0401": "Carbon-clogged EGR passages or a sticking EGR valve.",
        "P0420": "Catalytic converter worn out, a failing downstream O2 sensor, an exhaust leak, or past misfires that damaged the catalyst.",
        "P0430": "Bank 2 catalytic converter worn out, a failing downstream O2 sensor, or an exhaust leak.",
        "P0440": "Loose or damaged fuel cap, cracked EVAP hoses, or a faulty purge or vent valve.",
        "P0441": "Purge valve stuck or not opening, blocked purge line, or a damaged charcoal canister.",
        "P0442": "Small EVAP leak: fuel cap seal, cracked hose, or a leaking purge/vent valve.",
        "P0455": "Large EVAP leak: fuel cap missing or loose, a disconnected hose, or a vent valve stuck open.",
        "P0500": "Vehicle/wheel speed sensor or its wiring; on many cars the ABS module supplies this signal, so check for ABS codes too.",
        "P0501": "Speed sensor reading erratically — sensor, wiring, or an ABS-module fault.",
        "P0505": "Dirty throttle body or idle air control valve, or a vacuum leak.",
        "P0506": "Idle lower than expected: dirty throttle body, intake restriction, or a failing idle control.",
        "P0507": "Idle higher than expected: vacuum leak or a dirty/sticking throttle body.",
        "P0600": "Communication fault inside or between engine modules — check battery voltage, grounds and connectors first.",
        "P0601": "Engine computer memory checksum error — often needs the module reprogrammed or replaced by a shop.",
        "P0602": "Engine computer not programmed or programming incomplete — needs a dealer or specialist.",
        "P0603": "Engine computer lost its keep-alive memory — battery disconnects, weak battery, or a poor power/ground.",
        "P0605": "Engine computer internal fault — check power and grounds first; may need replacement.",
        "P0700": "The transmission computer has its own fault stored — read the transmission module (All Modules) for the real code.",
        "P0705": "Transmission range (gear selector) sensor misadjusted or failed, or its wiring.",
        "P0706": "Transmission range sensor misadjusted or failing.",
        "P0720": "Transmission output speed sensor or its wiring.",
        "P0730": "Low or worn transmission fluid, slipping clutches, or a faulty shift solenoid.",
        "P0841": "Low transmission fluid or a failing fluid pressure sensor/switch.",
        "P2002": "Diesel particulate filter clogged — often from many short trips; it may need a regeneration drive or service.",
        "P2004": "Intake runner flaps stuck from carbon build-up, or a failed runner actuator or linkage.",
        "P2006": "Intake runner flaps stuck from carbon build-up, or a failed runner actuator or linkage.",
        "P2101": "Electronic throttle body dirty or failing, or its wiring/connector.",
        "P2122": "Accelerator pedal sensor or its wiring.",
        "P2135": "The two throttle position sensors disagree — throttle body or its connector/wiring.",
        "P2138": "The two accelerator pedal sensors disagree — pedal assembly or its wiring.",
        "P2181": "Cooling system not reaching or holding temperature: thermostat, low coolant, or a coolant temperature sensor.",
        "P2237": "Front O2 sensor or its wiring.",
        "P2251": "Front O2 sensor or its wiring.",
        "P2302": "Ignition coil, spark plug, or coil wiring on that coil.",
        "P2401": "EVAP leak detection pump or its wiring.",
        "P2402": "EVAP leak detection pump or its wiring.",
        "P2422": "EVAP vent valve stuck closed, often from debris or a blocked vent filter.",
        "P2500": "Alternator or its control wiring.",
        "P2501": "Alternator or its control wiring.",
        "P2503": "Charging voltage low: alternator, slipping belt, weak battery, or corroded cables.",
        "P2A00": "Aging front O2 sensor, or an exhaust leak near it.",
        "U0001": "CAN bus wiring or connector fault, a failing module pulling the bus down, or low battery voltage.",
        "U0073": "CAN bus wiring or connector fault, or a module pulling the bus down; check battery voltage first.",
        "U0100": "Low battery voltage, a loose engine computer connector, CAN wiring, or the engine computer itself.",
        "U0121": "ABS module not communicating: low voltage, its fuse or connector, CAN wiring, or the ABS module itself.",
    ]

    private static func patterned(_ code: String) -> String? {
        guard code.count == 5, code.hasPrefix("P0"), let n = Int(code.dropFirst()) else { return nil }
        let letters = ["A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "L", "M"]
        switch n {
        case 301...312: return "Cylinder \(n - 300) misfire detected"
        case 201...212: return "Injector circuit malfunction — cylinder \(n - 200)"
        case 351...362: return "Ignition coil \(letters[n - 351]) primary/secondary circuit"
        case 130...147, 150...167:
            let bank = n < 150 ? 1 : 2
            let idx = n - (bank == 1 ? 130 : 150)
            let faults = ["circuit malfunction", "circuit low voltage", "circuit high voltage",
                          "circuit slow response", "circuit no activity", "heater circuit"]
            return "O2 sensor bank \(bank) sensor \(idx / 6 + 1) — \(faults[idx % 6])"
        default: return nil
        }
    }

    static let known: [String: String] = [
        "P0010": "Camshaft position actuator circuit (bank 1)",
        "P0011": "Camshaft timing over-advanced (bank 1)",
        "P0012": "Camshaft timing over-retarded (bank 1)",
        "P0016": "Crankshaft/camshaft position correlation (bank 1 sensor A)",
        "P0017": "Crankshaft/camshaft position correlation (bank 1 sensor B)",
        "P0018": "Crankshaft/camshaft position correlation (bank 2 sensor A)",
        "P0020": "Camshaft position actuator circuit (bank 2)",
        "P0021": "Camshaft timing over-advanced (bank 2)",
        "P0022": "Camshaft timing over-retarded (bank 2)",
        "P0030": "HO2S heater control circuit (bank 1 sensor 1)",
        "P0036": "HO2S heater control circuit (bank 1 sensor 2)",
        "P0050": "HO2S heater control circuit (bank 2 sensor 1)",
        "P0068": "MAP/MAF – throttle position correlation",
        "P0087": "Fuel rail/system pressure too low",
        "P0088": "Fuel rail/system pressure too high",
        "P0100": "Mass air flow circuit malfunction",
        "P0101": "Mass air flow circuit range/performance",
        "P0102": "Mass air flow circuit low input",
        "P0103": "Mass air flow circuit high input",
        "P0105": "Manifold absolute pressure circuit malfunction",
        "P0106": "Manifold absolute pressure range/performance",
        "P0107": "Manifold absolute pressure circuit low input",
        "P0108": "Manifold absolute pressure circuit high input",
        "P0110": "Intake air temperature circuit malfunction",
        "P0112": "Intake air temperature circuit low input",
        "P0113": "Intake air temperature circuit high input",
        "P0115": "Engine coolant temperature circuit malfunction",
        "P0116": "Engine coolant temperature range/performance",
        "P0117": "Engine coolant temperature circuit low input",
        "P0118": "Engine coolant temperature circuit high input",
        "P0120": "Throttle/pedal position sensor A circuit",
        "P0121": "Throttle/pedal position sensor A range/performance",
        "P0122": "Throttle/pedal position sensor A low input",
        "P0123": "Throttle/pedal position sensor A high input",
        "P0125": "Insufficient coolant temperature for closed-loop fuel control",
        "P0128": "Coolant thermostat (coolant below regulating temperature)",
        "P0171": "System too lean (bank 1)",
        "P0172": "System too rich (bank 1)",
        "P0174": "System too lean (bank 2)",
        "P0175": "System too rich (bank 2)",
        "P0190": "Fuel rail pressure sensor circuit",
        "P0191": "Fuel rail pressure sensor range/performance",
        "P0217": "Engine overtemperature condition",
        "P0219": "Engine overspeed condition",
        "P0221": "Throttle/pedal position sensor B range/performance",
        "P0234": "Turbo/supercharger overboost condition",
        "P0236": "Turbo boost sensor A range/performance",
        "P0299": "Turbo/supercharger underboost",
        "P0300": "Random/multiple cylinder misfire detected",
        "P0313": "Misfire detected with low fuel",
        "P0314": "Single cylinder misfire (cylinder not specified)",
        "P0316": "Misfire detected on startup (first 1000 revolutions)",
        "P0321": "Ignition/distributor engine speed input range/performance",
        "P0325": "Knock sensor 1 circuit (bank 1)",
        "P0327": "Knock sensor 1 circuit low input (bank 1)",
        "P0328": "Knock sensor 1 circuit high input (bank 1)",
        "P0330": "Knock sensor 2 circuit (bank 2)",
        "P0332": "Knock sensor 2 circuit low input (bank 2)",
        "P0335": "Crankshaft position sensor A circuit",
        "P0336": "Crankshaft position sensor A range/performance",
        "P0340": "Camshaft position sensor A circuit (bank 1)",
        "P0341": "Camshaft position sensor A range/performance (bank 1)",
        "P0345": "Camshaft position sensor A circuit (bank 2)",
        "P0400": "Exhaust gas recirculation flow malfunction",
        "P0401": "EGR flow insufficient",
        "P0402": "EGR flow excessive",
        "P0410": "Secondary air injection system malfunction",
        "P0411": "Secondary air injection incorrect flow",
        "P0420": "Catalyst efficiency below threshold (bank 1)",
        "P0421": "Warm-up catalyst efficiency below threshold (bank 1)",
        "P0430": "Catalyst efficiency below threshold (bank 2)",
        "P0431": "Warm-up catalyst efficiency below threshold (bank 2)",
        "P0440": "Evaporative emission system malfunction",
        "P0441": "EVAP incorrect purge flow",
        "P0442": "EVAP small leak detected",
        "P0443": "EVAP purge control valve circuit",
        "P0446": "EVAP vent control circuit",
        "P0455": "EVAP large leak detected (check fuel cap)",
        "P0456": "EVAP very small leak detected",
        "P0457": "EVAP leak detected (fuel cap loose/off)",
        "P0460": "Fuel level sensor circuit",
        "P0480": "Cooling fan 1 control circuit",
        "P0481": "Cooling fan 2 control circuit",
        "P0500": "Vehicle speed sensor malfunction",
        "P0505": "Idle control system malfunction",
        "P0506": "Idle RPM lower than expected",
        "P0507": "Idle RPM higher than expected",
        "P0520": "Engine oil pressure sensor/switch circuit",
        "P0521": "Engine oil pressure sensor range/performance",
        "P0524": "Engine oil pressure too low",
        "P0560": "System voltage malfunction",
        "P0562": "System voltage low",
        "P0563": "System voltage high",
        "P0600": "Serial communication link malfunction",
        "P0601": "Control module memory checksum error",
        "P0602": "Control module programming error",
        "P0603": "Control module keep-alive memory (KAM) error",
        "P0604": "Control module RAM error",
        "P0605": "Control module ROM error",
        "P0606": "Control module processor fault",
        "P0607": "Control module performance",
        "P0627": "Fuel pump control circuit open",
        "P0638": "Throttle actuator control range/performance (bank 1)",
        "P0700": "Transmission control system (TCM has a code stored)",
        "P0705": "Transmission range sensor circuit",
        "P0710": "Transmission fluid temperature sensor circuit",
        "P0715": "Input/turbine speed sensor circuit",
        "P0720": "Output speed sensor circuit",
        "P0730": "Incorrect gear ratio",
        "P0741": "Torque converter clutch performance / stuck off",
        "P0750": "Shift solenoid A malfunction",
        "P0755": "Shift solenoid B malfunction",
        "P0811": "Excessive clutch slippage",
        "P0841": "Transmission fluid pressure sensor/switch A range/performance",
        "P2096": "Post-catalyst fuel trim system too lean (bank 1)",
        "P2097": "Post-catalyst fuel trim system too rich (bank 1)",
        "P2098": "Post-catalyst fuel trim system too lean (bank 2)",
        "P2099": "Post-catalyst fuel trim system too rich (bank 2)",
        "P2101": "Throttle actuator control motor circuit range/performance",
        "P2135": "Throttle/pedal position sensor A/B voltage correlation",
        "P2138": "Pedal position sensor D/E voltage correlation",
        "P2181": "Cooling system performance",
        "P2187": "System too lean at idle (bank 1)",
        "P2188": "System too rich at idle (bank 1)",
        "P2189": "System too lean at idle (bank 2)",
        "P2191": "System too lean at higher load (bank 1)",
        "P2195": "O2 sensor signal stuck lean (bank 1 sensor 1)",
        "P2196": "O2 sensor signal stuck rich (bank 1 sensor 1)",
        "P2197": "O2 sensor signal stuck lean (bank 2 sensor 1)",
        "P2270": "O2 sensor signal stuck lean (bank 1 sensor 2)",
        "P2279": "Intake air system leak",
        "P2293": "Fuel pressure regulator 2 performance",
        "P2563": "Turbo boost control position sensor range/performance",
        "P0013": "Camshaft position actuator B circuit/open (bank 1)",
        "P0014": "Camshaft position B timing over-advanced or system performance (bank 1)",
        "P0200": "Injector circuit/open",
        "P0501": "Vehicle speed sensor A range/performance",
        "P0706": "Transmission range sensor circuit range/performance",
        "P0842": "Transmission fluid pressure sensor/switch A circuit low",
        "P0845": "Transmission fluid pressure sensor/switch B circuit",
        "P0846": "Transmission fluid pressure sensor/switch B circuit range/performance",
        "P0847": "Transmission fluid pressure sensor/switch B circuit low",
        "P0901": "Clutch actuator circuit range/performance",
        "P0935": "Hydraulic pressure sensor circuit high input",
        "P0942": "Hydraulic pressure unit",
        "P0944": "Hydraulic pressure unit loss of pressure",
        "P0961": "Pressure control solenoid A control circuit range/performance",
        "P0A08": "DC/DC converter status circuit",
        "P0A0D": "High-voltage system interlock circuit high",
        "P0A0F": "Engine failed to start",
        "P0A7F": "Hybrid battery pack deterioration",
        "P0A80": "Replace hybrid battery pack",
        "P2000": "NOx trap efficiency below threshold (bank 1)",
        "P2002": "Diesel particulate filter efficiency below threshold (bank 1)",
        "P2004": "Intake manifold runner control stuck open (bank 1)",
        "P2006": "Intake manifold runner control stuck closed (bank 1)",
        "P2122": "Throttle/pedal position sensor D circuit low input",
        "P2237": "O2 sensor positive current control circuit/open (bank 1 sensor 1)",
        "P2238": "O2 sensor positive current control circuit low (bank 1 sensor 1)",
        "P2251": "O2 sensor negative current control circuit/open (bank 1 sensor 1)",
        "P2302": "Ignition coil A secondary circuit",
        "P2303": "Ignition coil B primary control circuit low",
        "P2305": "Ignition coil B secondary circuit",
        "P2308": "Ignition coil C secondary circuit",
        "P2310": "Ignition coil D primary control circuit high",
        "P2401": "EVAP leak detection pump control circuit low",
        "P2402": "EVAP leak detection pump control circuit high",
        "P2422": "EVAP system vent valve stuck closed",
        "P2431": "Secondary air injection air flow/pressure sensor circuit range/performance (bank 1)",
        "P2432": "Secondary air injection air flow/pressure sensor circuit low (bank 1)",
        "P2500": "Generator lamp/L-terminal circuit low",
        "P2501": "Generator lamp/L-terminal circuit high",
        "P2503": "Charging system voltage low",
        "P2509": "ECM/PCM power input signal intermittent",
        "P250C": "Engine oil level sensor circuit low",
        "P2601": "Coolant pump control circuit range/performance",
        "P2609": "Intake air heater system performance",
        "P2610": "ECM/PCM internal engine-off timer performance",
        "P2614": "Camshaft position signal output circuit/open",
        "P2706": "Shift solenoid F",
        "P2711": "Unexpected mechanical gear disengagement",
        "P2714": "Pressure control solenoid D performance or stuck off",
        "P2716": "Pressure control solenoid D electrical",
        "P2723": "Pressure control solenoid E performance or stuck off",
        "P2803": "Transmission range sensor B circuit high",
        "P2A00": "O2 sensor circuit range/performance (bank 1 sensor 1)",
        "P2A01": "O2 sensor circuit range/performance (bank 1 sensor 2)",
        "P2A03": "O2 sensor circuit range/performance (bank 2 sensor 1)",
        "P2A04": "O2 sensor circuit range/performance (bank 2 sensor 2)",
        "P3400": "Cylinder deactivation system (bank 1)",
        "P3401": "Cylinder 1 deactivation/intake valve control circuit/open",
        "U0073": "Control module communication bus A off",
        "U0107": "Lost communication with throttle actuator control module",
        "U0001": "High-speed CAN communication bus",
        "U0100": "Lost communication with engine control module (ECM/PCM)",
        "U0101": "Lost communication with transmission control module (TCM)",
        "U0121": "Lost communication with ABS control module",
        "U0140": "Lost communication with body control module",
        "U0151": "Lost communication with airbag (restraints) module",
        "U0155": "Lost communication with instrument cluster",
        "U0401": "Invalid data received from ECM/PCM",
    ]
}

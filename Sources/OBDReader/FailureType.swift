import Foundation

/// SAE J2012 / ISO 15031-6 failure type byte (the "-1C" after a module code): how the part failed.
/// Every value here is confirmed by at least two sources — Volvo Trucks service information,
/// Jaguar Land Rover IDS DTC indexes, Ford workshop manuals and a Ford/TRW spec filed with NHTSA.
/// GM uses its own "symptom byte" in this position, so GM codes are not translated.
enum FailureType {
    static let names: [UInt8: String] = [
        0x00: "no sub-type information",
        0x01: "general electrical failure", 0x02: "general signal failure", 0x03: "FM/PWM failure",
        0x04: "system internal failure", 0x05: "system programming failure", 0x06: "algorithm-based failure",
        0x07: "mechanical failure", 0x08: "bus signal/message failure", 0x09: "component failure",
        0x11: "circuit short to ground", 0x12: "circuit short to battery", 0x13: "circuit open",
        0x14: "circuit short to ground or open", 0x15: "circuit short to battery or open",
        0x16: "circuit voltage below threshold", 0x17: "circuit voltage above threshold",
        0x18: "circuit current below threshold", 0x19: "circuit current above threshold",
        0x1A: "circuit resistance below threshold", 0x1B: "circuit resistance above threshold",
        0x1C: "circuit voltage out of range", 0x1D: "circuit current out of range",
        0x1E: "circuit resistance out of range", 0x1F: "circuit intermittent",
        0x21: "signal amplitude below minimum", 0x22: "signal amplitude above maximum",
        0x23: "signal stuck low", 0x24: "signal stuck high", 0x25: "signal shape/waveform failure",
        0x26: "signal rate of change below threshold", 0x27: "signal rate of change above threshold",
        0x28: "signal bias level out of range / zero adjustment failure", 0x29: "signal invalid",
        0x2F: "signal erratic",
        0x31: "no signal", 0x32: "signal low time below minimum", 0x33: "signal low time above maximum",
        0x34: "signal high time below minimum", 0x35: "signal high time above maximum",
        0x36: "signal frequency too low", 0x37: "signal frequency too high", 0x38: "signal frequency incorrect",
        0x39: "signal has too few pulses", 0x3A: "signal has too many pulses",
        0x41: "general checksum failure", 0x42: "general memory failure", 0x43: "special memory failure",
        0x44: "data memory failure", 0x45: "program memory failure", 0x46: "calibration/parameter memory failure",
        0x47: "watchdog/safety processor failure", 0x48: "supervision software failure",
        0x49: "internal electronic failure", 0x4A: "incorrect component installed", 0x4B: "over temperature",
        0x51: "not programmed", 0x52: "not activated", 0x53: "deactivated", 0x54: "missing calibration",
        0x55: "not configured", 0x56: "invalid/incompatible configuration", 0x57: "invalid/incompatible software component",
        0x61: "signal calculation failure", 0x62: "signal compare failure", 0x63: "circuit/component protection time-out",
        0x64: "signal plausibility failure", 0x65: "signal has too few transitions/events",
        0x66: "signal has too many transitions/events", 0x67: "signal incorrect after event", 0x68: "event information",
        0x71: "actuator stuck", 0x72: "actuator stuck open", 0x73: "actuator stuck closed", 0x74: "actuator slipping",
        0x75: "emergency position not reachable", 0x76: "wrong mounting position", 0x77: "commanded position not reachable",
        0x78: "alignment or adjustment incorrect", 0x79: "mechanical linkage failure", 0x7A: "fluid leak or seal failure",
        0x7B: "low fluid level",
        0x81: "invalid serial data received", 0x82: "alive/sequence counter incorrect or not updated",
        0x83: "signal protection value incorrect", 0x84: "signal below allowable range", 0x85: "signal above allowable range",
        0x86: "signal invalid", 0x87: "missing message", 0x88: "bus off",
        0x91: "parametric", 0x92: "performance or incorrect operation", 0x93: "no operation",
        0x94: "unexpected operation", 0x95: "incorrect assembly", 0x96: "component internal failure",
        0x97: "component or system operation obstructed or blocked", 0x98: "component or system over temperature",
        0x9A: "component or system operating conditions",
    ]

    /// Meaning of a failure type byte, or nil when there's nothing to say (0 or unknown on GM).
    static func describe(_ ftb: UInt8, make: String?) -> String? {
        guard ftb != 0 else { return nil }
        let m = (make ?? "").lowercased()
        if m == "gm" || ["chevrolet", "chevy", "gmc", "cadillac", "buick", "general motors", "holden", "opel", "vauxhall"].contains(where: { m.contains($0) }) {
            return String(format: "GM symptom %02X (GM's own meaning — see GM service information)", Int(ftb))
        }
        if let n = names[ftb] { return n }
        if ftb >= 0xF0 { return "manufacturer-specific failure type" }
        return "unlisted failure type"
    }
}

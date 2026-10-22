import Foundation
import AppKit
import UserNotifications

// MARK: - Speed estimate (past the OBD-II 158 mph ceiling)

/// Learns the engine-speed-to-road-speed ratio while the OBD speed is still trustworthy, then
/// estimates road speed from RPM once PID 0x0D saturates at 255 km/h (158 mph). A rough backup
/// for a GPS receiver: it only works in gears it has already seen, and tyre growth at very high
/// speed makes it read a little high.
struct SpeedEstimator {
    private var ratios: [Double] = []      // rpm per km/h; the smallest is top gear
    private var lastSpeed = 0.0, lastRpm = 0.0
    private(set) var sampleCount = 0

    mutating func learn(rpm: Double, obdSpeedKmh: Double) {
        guard obdSpeedKmh > 55, obdSpeedKmh < 250, rpm > 1200 else {
            lastSpeed = obdSpeedKmh; lastRpm = rpm; return
        }
        // Only when steady, so a mid-shift sample doesn't pollute a gear's ratio.
        if abs(obdSpeedKmh - lastSpeed) < 4, abs(rpm - lastRpm) < 250 {
            ratios.append(rpm / obdSpeedKmh)
            sampleCount += 1
            if ratios.count > 600 { ratios.removeFirst(ratios.count - 600) }
        }
        lastSpeed = obdSpeedKmh; lastRpm = rpm
    }

    /// Top-gear ratio as the 5th percentile of rpm/speed, to shrug off a few noisy samples.
    var topGearRatio: Double? {
        guard ratios.count >= 20 else { return nil }
        let sorted = ratios.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.05))]
    }

    /// Estimated road speed (km/h) from RPM; nil until enough has been learned.
    func estimate(rpm: Double) -> Double? {
        guard let r = topGearRatio, r > 0 else { return nil }
        return rpm / r
    }

    var ready: Bool { topGearRatio != nil }
}

// MARK: - Trip computer

/// Integrates speed and fuel flow over time. Fuel comes from PID 5E (engine fuel rate) when the
/// car supports it, otherwise it's estimated from mass air flow assuming stoichiometric gasoline.
struct TripComputer {
    private(set) var started = Date()
    private(set) var distanceKm = 0.0
    private(set) var fuelL = 0.0
    private(set) var movingSeconds = 0.0
    private(set) var idleSeconds = 0.0
    private(set) var maxSpeedKmh = 0.0
    private(set) var fuelSource = "—"
    private var last: Date?

    mutating func reset() { self = TripComputer() }

    mutating func update(speed: Double?, fuelRate: Double?, maf: Double?, rpm: Double?, at now: Date = Date()) {
        defer { last = now }
        guard let prev = last else { return }
        let dt = now.timeIntervalSince(prev)
        guard dt > 0, dt < 5 else { return }          // ignore gaps (paused, reconnect)

        if let v = speed {
            distanceKm += v * dt / 3600
            maxSpeedKmh = max(maxSpeedKmh, v)
            if v > 1 { movingSeconds += dt } else if (rpm ?? 0) > 300 { idleSeconds += dt }
        }
        if let lph = fuelRate {
            fuelL += lph * dt / 3600
            fuelSource = "engine fuel-rate sensor"
        } else if let gps = maf {
            // g air/s ÷ 14.7 (air:fuel) ÷ 745 g/L (gasoline density)
            fuelL += gps / 14.7 / 745 * dt
            fuelSource = "estimated from air flow"
        }
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(started) }
    var averageSpeedKmh: Double { movingSeconds > 0 ? distanceKm / (movingSeconds / 3600) : 0 }
    var mpg: Double? { fuelL > 0.01 ? (distanceKm * 0.621371) / (fuelL * 0.264172) : nil }
    var litersPer100km: Double? { distanceKm > 0.1 ? fuelL / distanceKm * 100 : nil }
}

// MARK: - Performance timer

struct PerfRun: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var zeroToTarget: Double?        // seconds
    var targetLabel: String
    var quarterMile: Double?         // seconds
    var trapSpeedKmh: Double?
    var peakSpeedKmh: Double
}

/// 0–60 mph (or 0–100 km/h) and quarter-mile from the speed sensor.
/// Accuracy depends on how fast the car answers — typically ±0.1 s on CAN with only speed polled.
struct PerformanceTimer {
    enum Phase: Equatable { case off, waitingForStop, ready, running, finished }

    private(set) var phase: Phase = .off
    private(set) var elapsed = 0.0
    private(set) var distanceM = 0.0
    private(set) var speedKmh = 0.0
    private(set) var current: PerfRun?
    private(set) var samplesPerSecond = 0.0

    var targetKmh = 96.5604          // 60 mph
    var targetLabel = "0–60 mph"
    private var startTime: Date?
    private var lastT: Date?
    private var lastV = 0.0
    private var sampleTimes: [Date] = []

    mutating func arm(metric: Bool) {
        targetKmh = metric ? 100 : 96.5604
        targetLabel = metric ? "0–100 km/h" : "0–60 mph"
        phase = .waitingForStop
        current = nil
        elapsed = 0; distanceM = 0
    }

    mutating func cancel() { phase = .off }

    /// Feed one speed sample. Returns a finished run when the quarter mile completes (or the car stops).
    mutating func update(speed v: Double, at t: Date = Date()) -> PerfRun? {
        sampleTimes.append(t)
        sampleTimes.removeAll { t.timeIntervalSince($0) > 2 }
        samplesPerSecond = Double(sampleTimes.count) / 2
        defer { lastT = t; lastV = v; speedKmh = v }

        switch phase {
        case .off, .finished:
            return nil
        case .waitingForStop:
            if v < 0.5 { phase = .ready }
            return nil
        case .ready:
            guard v > 0.5, let t0 = lastT else { return nil }
            // Launch happened somewhere between the last zero sample and this one.
            let launch = t0.addingTimeInterval(t.timeIntervalSince(t0) / 2)
            startTime = launch
            phase = .running
            current = PerfRun(targetLabel: targetLabel, peakSpeedKmh: v)
            distanceM = v / 3.6 * t.timeIntervalSince(launch) / 2
            elapsed = t.timeIntervalSince(launch)
            return nil
        case .running:
            guard let start = startTime, let tPrev = lastT, var run = current else { return nil }
            let dt = t.timeIntervalSince(tPrev)
            let prevDist = distanceM
            distanceM += (lastV + v) / 2 / 3.6 * dt           // trapezoid
            elapsed = t.timeIntervalSince(start)
            run.peakSpeedKmh = max(run.peakSpeedKmh, v)

            if run.zeroToTarget == nil, v >= targetKmh, v > lastV {
                let frac = (targetKmh - lastV) / (v - lastV)
                run.zeroToTarget = tPrev.addingTimeInterval(dt * frac).timeIntervalSince(start)
            }
            if run.quarterMile == nil, distanceM >= 402.336, distanceM > prevDist {
                let frac = (402.336 - prevDist) / (distanceM - prevDist)
                run.quarterMile = tPrev.addingTimeInterval(dt * frac).timeIntervalSince(start)
                run.trapSpeedKmh = lastV + (v - lastV) * frac
            }
            current = run
            if run.quarterMile != nil || v < 0.5 || elapsed > 60 {
                phase = .finished
                return run
            }
            return nil
        }
    }
}

// MARK: - Alerts

@MainActor
final class AlertMonitor {
    private var lastFired: [UUID: Date] = [:]
    private var notificationsAuthorized = false

    init() {
        // Notification Center only works inside an .app bundle (not with `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.notificationsAuthorized = ok }
        }
    }

    /// Returns messages for rules that just tripped (each rule at most once per minute).
    func check(_ values: [UInt8: Double], rules: [AlertRule], units: UnitSystem) -> [String] {
        var fired: [String] = []
        let now = Date()
        for rule in rules where rule.enabled {
            guard let v = values[rule.pid], let def = PIDs.def(rule.pid) else { continue }
            var msg: String?
            if let hi = rule.above, v > hi { msg = "\(def.name) high: \(def.format(v, units)) (limit \(def.format(hi, units)))" }
            if let lo = rule.below, v < lo { msg = "\(def.name) low: \(def.format(v, units)) (limit \(def.format(lo, units)))" }
            guard let msg else { continue }
            if let last = lastFired[rule.id], now.timeIntervalSince(last) < 60 { continue }
            lastFired[rule.id] = now
            fired.append(msg)
            notify(msg)
        }
        return fired
    }

    /// Sound + notification for a one-off warning that isn't tied to a rule (e.g. battery drain).
    func announce(_ text: String) { notify(text) }

    private func notify(_ text: String) {
        NSSound(named: "Funk")?.play()
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "OBD Reader alert"
        content.body = text
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Track day: GPS lap timer, g-meter, data log

struct TrackPoint {
    let t: Date
    let lap: Int
    let lat: Double?
    let lon: Double?
    let kmh: Double
    let gLong: Double        // + accelerating, − braking
    let gLat: Double         // + turning right, − turning left
    let rpm: Double?
    let throttle: Double?
}

struct Lap: Identifiable {
    let number: Int
    let time: TimeInterval
    let maxKmh: Double
    let maxGLat: Double
    var id: Int { number }
}

/// Lap timing from a GPS start/finish point, plus longitudinal and lateral g.
/// Longitudinal g comes from the change in speed (works with OBD speed alone); lateral g needs a
/// GPS course (v × rate of turn). A 10 Hz receiver gives usable laps; 1 Hz is only rough.
struct TrackSession {
    static let gateRadius = 25.0          // metres around the start/finish point
    static let minLap: TimeInterval = 20  // ignore re-crossings faster than this

    var startLine: (lat: Double, lon: Double)?
    private(set) var points: [TrackPoint] = []
    private(set) var laps: [Lap] = []
    private(set) var lapStart: Date?
    private(set) var gLong = 0.0
    private(set) var gLat = 0.0
    private(set) var peakGLat = 0.0
    private(set) var peakBrake = 0.0
    private(set) var peakAccel = 0.0
    private var lapMaxKmh = 0.0, lapMaxGLat = 0.0
    private var last: (t: Date, v: Double, course: Double?, lat: Double?, lon: Double?)?
    private var inGate = false
    private var gateBest: (d: Double, t: Date)?

    var currentLap: Int { laps.count + (lapStart == nil ? 0 : 1) }
    var bestLap: Lap? { laps.min { $0.time < $1.time } }
    var lastLap: Lap? { laps.last }
    var currentLapTime: TimeInterval? { lapStart.map { Date().timeIntervalSince($0) } }

    mutating func reset() {
        let s = startLine
        self = TrackSession()
        startLine = s
    }

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Feed one sample. `lat/lon/course` come from GPS when available.
    mutating func update(t: Date, kmh: Double, lat: Double?, lon: Double?, course: Double?,
                         rpm: Double?, throttle: Double?) {
        if let p = last {
            let dt = t.timeIntervalSince(p.t)
            guard dt >= 0.05 else { return }          // duplicate sentence for the same fix
            if dt < 3 {
                let v0 = p.v / 3.6, v1 = kmh / 3.6
                let rawLong = (v1 - v0) / dt / 9.81
                // Course: from the receiver, else from the movement between fixes.
                var c1 = course
                if c1 == nil, let a = p.lat, let b = p.lon, let la = lat, let lo = lon,
                   Self.distance(a, b, la, lo) > 2 { c1 = Self.bearing(a, b, la, lo) }
                var rawLat = 0.0
                if let c0 = p.course, let c1, v1 > 3 {
                    var dTheta = (c1 - c0) * .pi / 180
                    while dTheta > .pi { dTheta -= 2 * .pi }
                    while dTheta < -.pi { dTheta += 2 * .pi }
                    rawLat = v1 * (dTheta / dt) / 9.81
                }
                // Light smoothing; GPS-derived g is noisy.
                gLong = gLong * 0.6 + max(-3, min(3, rawLong)) * 0.4
                gLat = gLat * 0.6 + max(-3, min(3, rawLat)) * 0.4
                peakGLat = max(peakGLat, abs(gLat))
                peakAccel = max(peakAccel, gLong)
                peakBrake = max(peakBrake, -gLong)
                lapMaxGLat = max(lapMaxGLat, abs(gLat))
                last = (t, kmh, c1 ?? p.course, lat ?? p.lat, lon ?? p.lon)
            } else {
                last = (t, kmh, course, lat, lon)
            }
        } else {
            last = (t, kmh, course, lat, lon)
        }
        lapMaxKmh = max(lapMaxKmh, kmh)

        // Start/finish: the crossing is the moment of closest approach while inside the gate.
        if let s = startLine, let la = lat, let lo = lon {
            let d = Self.distance(s.lat, s.lon, la, lo)
            if d < Self.gateRadius {
                inGate = true
                if gateBest == nil || d < gateBest!.d { gateBest = (d, t) }
            } else if inGate {
                inGate = false
                if let cross = gateBest?.t {
                    if let start = lapStart {
                        let time = cross.timeIntervalSince(start)
                        if time >= Self.minLap {
                            laps.append(Lap(number: laps.count + 1, time: time, maxKmh: lapMaxKmh, maxGLat: lapMaxGLat))
                            lapStart = cross
                            lapMaxKmh = 0; lapMaxGLat = 0
                        }
                    } else {
                        lapStart = cross
                        lapMaxKmh = 0; lapMaxGLat = 0
                    }
                }
                gateBest = nil
            }
        }

        points.append(TrackPoint(t: t, lap: currentLap, lat: lat, lon: lon, kmh: kmh,
                                 gLong: gLong, gLat: gLat, rpm: rpm, throttle: throttle))
        if points.count > 50_000 { points.removeFirst(points.count - 50_000) }
    }

    func csv(metric: Bool) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = "timestamp,lap,latitude,longitude,speed_\(metric ? "kmh" : "mph"),g_long,g_lat,rpm,throttle_pct\n"
        for p in points {
            let v = metric ? p.kmh : p.kmh * 0.621371
            let row: [String] = [iso.string(from: p.t), "\(p.lap)",
                    p.lat.map { String(format: "%.7f", $0) } ?? "",
                    p.lon.map { String(format: "%.7f", $0) } ?? "",
                    String(format: "%.1f", v), String(format: "%.3f", p.gLong), String(format: "%.3f", p.gLat),
                    p.rpm.map { String(format: "%.0f", $0) } ?? "",
                    p.throttle.map { String(format: "%.1f", $0) } ?? ""]
            out += row.joined(separator: ",") + "\n"
        }
        return out
    }
}

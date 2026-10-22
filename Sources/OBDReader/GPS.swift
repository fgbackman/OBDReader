import Foundation
import Darwin

/// Reads speed from a USB NMEA-0183 GPS receiver on its own serial port. Optional, and separate
/// from the OBD adapter: it gives real road speed above the OBD-II 255 km/h (158 mph) ceiling and
/// times performance runs more precisely. A 5–10 Hz receiver is ideal.
final class GPSReceiver {
    struct Reading {
        let kmh: Double
        let age: TimeInterval
        let satellites: Int
        var lat: Double? = nil          // degrees, + north
        var lon: Double? = nil          // degrees, + east
        var course: Double? = nil       // degrees true, direction of travel
        var fixTime = Date.distantPast  // when this fix arrived; changes once per fix
    }

    private var fd: Int32 = -1
    private let lock = NSLock()
    private var _speedKmh: Double?
    private var _lastFix = Date.distantPast
    private var _satellites = 0
    private var _lat: Double?
    private var _lon: Double?
    private var _course: Double?
    private var running = false
    private var thread: Thread?

    /// The most recent speed, with how long ago it arrived. nil until the first fix.
    var reading: Reading? {
        lock.lock(); defer { lock.unlock() }
        guard let s = _speedKmh else { return nil }
        return Reading(kmh: s, age: Date().timeIntervalSince(_lastFix), satellites: _satellites,
                       lat: _lat, lon: _lon, course: _course, fixTime: _lastFix)
    }

    /// Common NMEA baud rates, fastest first (10 Hz receivers usually run at 115200 or 38400).
    static let bauds = [9600, 4800, 38400, 57600, 115200]

    func open(path: String, baud: Int) -> Bool {
        fd = Darwin.open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        _ = fcntl(fd, F_SETFL, 0)
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { Darwin.close(fd); fd = -1; return false }
        cfmakeraw(&t)
        cfsetispeed(&t, speed_t(baud))
        cfsetospeed(&t, speed_t(baud))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in cc[Int(VMIN)] = 0; cc[Int(VTIME)] = 2 }
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { Darwin.close(fd); fd = -1; return false }

        running = true
        let th = Thread { [weak self] in self?.readLoop() }
        th.stackSize = 1 << 18
        thread = th
        th.start()
        return true
    }

    func close() {
        running = false
        thread = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private func readLoop() {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 512)
        while running {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buf.append(contentsOf: chunk[0..<n])
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = String(decoding: buf[..<nl], as: UTF8.self)
                    buf.removeFirst(nl + 1)
                    parse(line)
                }
                if buf.count > 4096 { buf.removeAll(keepingCapacity: true) }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// Pull speed from the two sentences that carry it, from any talker (GP, GN, GL…).
    private func parse(_ line: String) {
        let f = line.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",")
        guard let tag = f.first, tag.count >= 6 else { return }
        let type = tag.suffix(3)
        switch type {
        case "VTG" where f.count > 8:                 // course,T,…,sog,N,kph,K → field 7 is km/h
            if let c = Double(f[1]) { lock.lock(); _course = c; lock.unlock() }
            if let kmh = Double(f[7]) { set(kmh) }
        case "RMC" where f.count > 8 && f[2] == "A":  // 3/4 lat, 5/6 lon, 7 knots, 8 course; 2 = A/V status
            let lat = Self.degrees(f[3], f[4]), lon = Self.degrees(f[5], f[6])
            lock.lock()
            if let lat, let lon { _lat = lat; _lon = lon }
            if let c = Double(f[8]) { _course = c }
            lock.unlock()
            if let knots = Double(f[7]) { set(knots * 1.852) }
        case "GGA" where f.count > 7:                 // field 7 is the satellite count
            if let sats = Int(f[7]) { lock.lock(); _satellites = sats; lock.unlock() }
        default:
            break
        }
    }

    /// NMEA "ddmm.mmmm" / "dddmm.mmmm" + hemisphere → signed decimal degrees.
    static func degrees(_ value: String, _ hemi: String) -> Double? {
        guard let v = Double(value), v > 0 else { return nil }
        let deg = (v / 100).rounded(.down)
        let d = deg + (v - deg * 100) / 60
        return (hemi == "S" || hemi == "W") ? -d : d
    }

    private func set(_ kmh: Double) {
        lock.lock(); _speedKmh = kmh; _lastFix = Date(); lock.unlock()
    }
}

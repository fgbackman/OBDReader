import Foundation
import Darwin

/// A byte pipe to an ELM327-compatible adapter (USB serial or the built-in simulator).
protocol Transport: AnyObject {
    var name: String { get }
    func open() throws
    func close()
    /// Send one command line (no terminator) and return everything up to the '>' prompt.
    func send(_ command: String, timeout: TimeInterval) throws -> String
    /// Send a monitor command (ATMA), collect what the adapter prints for `seconds`, then stop it
    /// (any character stops monitoring) and return everything up to the prompt.
    func monitor(_ command: String, seconds: TimeInterval) throws -> String
}

extension Transport {
    func monitor(_ command: String, seconds: TimeInterval) throws -> String {
        throw TransportError.io("This connection can't listen to the bus (recordings don't include bus traffic).")
    }
}

enum TransportError: LocalizedError {
    case openFailed(String)
    case notOpen
    case timeout(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let s): return "Couldn't open the adapter: \(s)"
        case .notOpen: return "The adapter isn't connected."
        case .timeout(let c): return "The adapter didn't answer \"\(c)\" in time."
        case .io(let s): return "Serial error: \(s)"
        }
    }
}

// MARK: - USB serial (FTDI / CP210x / CH340 adapters show up as /dev/cu.*)

final class SerialTransport: Transport {
    let path: String
    let baud: Int
    private var fd: Int32 = -1

    var name: String { (path as NSString).lastPathComponent }

    init(path: String, baud: Int = 115200) {
        self.path = path
        self.baud = baud
    }

    /// Serial ports macOS currently exposes. USB adapters are listed first.
    static func availablePorts() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let ports = all.filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming") }
            .map { "/dev/" + $0 }
        return ports.sorted { a, b in
            let ua = a.contains("usbserial") || a.contains("usbmodem") || a.contains("SLAB") || a.contains("wchusb")
            let ub = b.contains("usbserial") || b.contains("usbmodem") || b.contains("SLAB") || b.contains("wchusb")
            return ua == ub ? a < b : ua
        }
    }

    func open() throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw TransportError.openFailed(String(cString: strerror(errno))) }
        // Back to blocking mode; reads are bounded by VMIN/VTIME below.
        _ = fcntl(fd, F_SETFL, 0)

        var t = termios()
        guard tcgetattr(fd, &t) == 0 else {
            Darwin.close(fd); fd = -1
            throw TransportError.openFailed("tcgetattr failed")
        }
        cfmakeraw(&t)
        cfsetispeed(&t, speed_t(baud))
        cfsetospeed(&t, speed_t(baud))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)   // no hardware flow control
        // VMIN = 0, VTIME = 1  → read() returns after at most 0.1 s.
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1
        }
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            Darwin.close(fd); fd = -1
            throw TransportError.openFailed("tcsetattr failed")
        }
        tcflush(fd, TCIOFLUSH)
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    func send(_ command: String, timeout: TimeInterval) throws -> String {
        guard fd >= 0 else { throw TransportError.notOpen }
        tcflush(fd, TCIFLUSH)
        let line = Array((command + "\r").utf8)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw TransportError.io("write failed") }

        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw TransportError.io(String(cString: strerror(errno))) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.contains(UInt8(ascii: ">")) {
                    return String(decoding: buffer, as: UTF8.self)
                }
            }
        }
        throw TransportError.timeout(command)
    }

    func monitor(_ command: String, seconds: TimeInterval) throws -> String {
        guard fd >= 0 else { throw TransportError.notOpen }
        tcflush(fd, TCIFLUSH)
        let line = Array((command + "\r").utf8)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw TransportError.io("write failed") }

        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw TransportError.io(String(cString: strerror(errno))) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                // The adapter stopped by itself (e.g. BUFFER FULL) and is back at the prompt.
                if chunk[0..<n].contains(UInt8(ascii: ">")) { return String(decoding: buffer, as: UTF8.self) }
            }
        }
        // Any character stops monitoring; the adapter then prints the prompt.
        let stop: [UInt8] = [0x0D]
        _ = stop.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let stopDeadline = Date().addingTimeInterval(2)
        while Date() < stopDeadline {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw TransportError.io(String(cString: strerror(errno))) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if chunk[0..<n].contains(UInt8(ascii: ">")) { break }
            }
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}

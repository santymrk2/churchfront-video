import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// AVMATRIX switcher control over the network (PVS0403U, HVS0403U, HVS0402U and the
// other models AVMATRIX's own "0403" control software drives), with no AVMATRIX
// software installed.
//
// The protocol is AVMATRIX's own ("PVS0403U-API V3.1" / "0403API V3.1"), as used by
// the open source Companion module (github.com/lygilygi/companion-module-avmatrix):
//
// - UDP. Commands go to port 19523 on the switcher. The switcher answers, and reports
//   every change, to port 19522 on this computer, so only one program on a computer can
//   listen to it: AVMATRIX's own control software has to be closed.
// - Each frame: 5A, total length (2 bytes, low first), device type 00, device ID 00,
//   reserved 00, data length (the command byte plus its data), command, data,
//   checksum (sum of every byte before it, low 8 bits), DD.
// - Commands: 12 program source, 13 preview source (1 to 4 the inputs, 5 the pattern),
//   11 [type, value] transitions (01 auto, 02 cut, 03 fade to black on/off, 05 mute),
//   20 key states (six bytes: luma, chroma, PIP 1, PIP 2, DSK, logo; bit 1 on air,
//   bit 0 in the next transition), 24 and 25 PIP 1 and 2 (source, size, x, y),
//   FE 01 asks for the whole state, FF 01 a keep-alive.
//
// The switcher's state is turned into an ATEMState with one M/E, so everything built on
// ATEMClient (Next and Live, tally, the camera safeguards, auto tracking) works unchanged.

public enum AVMatrixProtocol {
    public static let devicePort: UInt16 = 19523
    public static let localPort: UInt16 = 19522

    /// The pattern (color bars) source, shown as the ATEM's color bars input.
    public static let patternSource = 1000

    /// One whole frame for a command and its data.
    public static func frame(_ command: UInt8, _ data: [UInt8] = []) -> [UInt8] {
        var f: [UInt8] = [0x5A, 0, 0, 0x00, 0x00, 0x00, UInt8(clamping: 1 + data.count), command] + data
        let total = f.count + 2
        f[1] = UInt8(total & 0xFF)
        f[2] = UInt8((total >> 8) & 0xFF)
        let sum = f.reduce(0) { ($0 + Int($1)) & 0xFF }
        return f + [UInt8(sum), 0xDD]
    }

    /// The command and data of every whole frame in a datagram (normally one).
    public static func parse(_ bytes: [UInt8]) -> [(command: UInt8, data: [UInt8])] {
        var out: [(UInt8, [UInt8])] = []
        var i = 0
        while i + 10 <= bytes.count {
            guard bytes[i] == 0x5A else { i += 1; continue }
            let len = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
            guard len >= 10, i + len <= bytes.count, bytes[i + len - 1] == 0xDD else { i += 1; continue }
            let dataLen = Int(bytes[i + 6])
            if dataLen >= 1, 7 + dataLen <= len - 2 {
                out.append((bytes[i + 7], Array(bytes[(i + 8)..<(i + 7 + dataLen)])))
            }
            i += len
        }
        return out
    }

    /// The switcher's source number for an ATEM-style input number, if it has one.
    public static func source(forInput input: Int) -> UInt8? {
        if (1...4).contains(input) { return UInt8(input) }
        if input == patternSource { return 5 }
        return nil
    }

    /// The ATEM-style input number for one of the switcher's source numbers.
    public static func input(forSource source: Int) -> Int? {
        if (1...4).contains(source) { return source }
        if source == 5 { return patternSource }
        return nil
    }

    /// The switcher's commands for an ATEM command (as ATEMClient builds them), or nil
    /// when this switcher has nothing like it. `ftb` is whether it's faded to black now.
    public static func translate(_ name: String, _ d: [UInt8], ftb: Bool) -> [UInt8]? {
        func u16(_ i: Int) -> Int { i + 1 < d.count ? Int(d[i]) << 8 | Int(d[i + 1]) : -1 }
        let me = Int(d.first ?? 0)
        switch name {
        case "CPgI" where me == 0: return source(forInput: u16(2)).map { frame(0x12, [$0]) }
        case "CPvI" where me == 0: return source(forInput: u16(2)).map { frame(0x13, [$0]) }
        case "DCut" where me == 0: return frame(0x11, [0x02, 0x00])
        case "DAut" where me == 0: return frame(0x11, [0x01, 0x00])
        case "FtbA" where me == 0: return frame(0x11, [0x03, ftb ? 0x00 : 0x01])
        default: return nil
        }
    }
}

/// What the switcher has reported.
public struct AVMatrixStatus: Equatable {
    public var program: Int?
    public var preview: Int?
    public var ftb = false
    /// Luma, chroma, PIP 1, PIP 2, DSK, logo: bit 1 on air, bit 0 in the next transition.
    public var keys: [UInt8] = [0, 0, 0, 0, 0, 0]
    /// PIP sources: 0 black, 1 bars, 2 and 3 colors, 4 to 7 inputs 1 to 4, 8 image.
    public var pip1: Int?
    public var pip2: Int?

    public init() {}

    /// Takes in one frame from the switcher. True if it was a state report.
    @discardableResult
    public mutating func apply(_ command: UInt8, _ d: [UInt8]) -> Bool {
        switch command {
        case 0x12 where d.count >= 1: program = Int(d[0])
        case 0x13 where d.count >= 1: preview = Int(d[0])
        case 0x11 where d.count >= 2:
            if d[0] == 0x03 { ftb = d[1] != 0 }
        case 0x20 where d.count >= 6: keys = Array(d[0..<6])
        case 0x24 where d.count >= 1: pip1 = Int(d[0])
        case 0x25 where d.count >= 1: pip2 = Int(d[0])
        case 0x14, 0x01, 0x32: break
        default: return false
        }
        return true
    }

    /// The same state as an ATEM would report it: one M/E, inputs 1 to 4 and color bars,
    /// and tally that counts a camera shown in a PIP as on air.
    public func atemState() -> ATEMState {
        var s = ATEMState()
        s.product = "AVMATRIX"
        for i in 1...4 { s.inputs[i] = ATEMInput(id: i, long: "Input \(i)", short: "IN\(i)") }
        let bars = AVMatrixProtocol.patternSource
        s.inputs[bars] = ATEMInput(id: bars, long: "Pattern", short: "BARS")
        if let p = program.flatMap(AVMatrixProtocol.input(forSource:)) { s.program[0] = p }
        if let p = preview.flatMap(AVMatrixProtocol.input(forSource:)) { s.preview[0] = p }
        s.inTransition[0] = false
        s.position[0] = 0
        s.ftbBlack[0] = ftb
        s.ftbInTransition[0] = false

        var tally: [Int: UInt8] = [:]
        for id in s.inputs.keys { tally[id] = 0 }
        if let p = s.program[0] { tally[p, default: 0] |= 1 }
        if let p = s.preview[0] { tally[p, default: 0] |= 2 }
        for (pip, state) in [(pip1, keys[2]), (pip2, keys[3])] {
            guard let src = pip, (4...7).contains(src) else { continue }
            if state & 0x02 != 0 { tally[src - 3, default: 0] |= 1 }
            if state & 0x01 != 0 { tally[src - 3, default: 0] |= 2 }
        }
        s.tally = tally
        return s
    }
}

/// The connection to one AVMATRIX switcher. Calls back on its own queue.
public final class AVMatrixLink {
    public var onState: ((ATEMState) -> Void)?
    public var onLink: ((ATEMLink) -> Void)?

    public let host: String
    private let devicePort: UInt16
    private let localPort: UInt16
    private let queue = DispatchQueue(label: "cuevideo.avmatrix")
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var target = sockaddr_in()
    private var status = AVMatrixStatus()
    private var heard = false
    private var lastHeard = 0.0
    private var link: ATEMLink = .idle
    private var stopped = false

    public init(host: String, devicePort: UInt16 = AVMatrixProtocol.devicePort, localPort: UInt16 = AVMatrixProtocol.localPort) {
        self.host = host
        self.devicePort = devicePort
        self.localPort = localPort
    }

    public func start() { queue.async { self.open() } }

    public func stop() {
        queue.async {
            self.stopped = true
            self.timer?.cancel(); self.timer = nil
            self.reader?.cancel(); self.reader = nil
            self.fd = -1
        }
    }

    /// Sends the switcher's version of an ATEM command. False if this switcher has nothing
    /// like it. Program, preview, cut and auto also show at once, before the switcher
    /// reports them, so Live and Next (and the camera safeguards) never lag a press.
    public func perform(_ name: String, _ data: [UInt8]) -> Bool {
        guard let f = queue.sync(execute: { AVMatrixProtocol.translate(name, data, ftb: status.ftb) }) else { return false }
        queue.async {
            guard self.fd >= 0, self.heard else { return }
            self.send(f)
            var s = self.status
            switch name {
            case "CPgI": s.program = AVMatrixProtocol.source(forInput: Self.u16(data, 2)).map(Int.init)
            case "CPvI": s.preview = AVMatrixProtocol.source(forInput: Self.u16(data, 2)).map(Int.init)
            case "DCut", "DAut": (s.program, s.preview) = (s.preview, s.program)
            default: break
            }
            self.update(s)
            self.send(AVMatrixProtocol.frame(0xFE, [0x01]))
        }
        return queue.sync { fd >= 0 && heard }
    }

    private static func u16(_ d: [UInt8], _ i: Int) -> Int { i + 1 < d.count ? Int(d[i]) << 8 | Int(d[i + 1]) : -1 }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func setLink(_ l: ATEMLink) {
        guard l != link, !stopped else { return }
        link = l
        onLink?(l)
    }

    private func update(_ s: AVMatrixStatus) {
        status = s
        if heard, !stopped { onState?(s.atemState()) }
    }

    private func open() {
        guard !stopped else { return }
        // A retry after "port in use" stays offline until it works, rather than flickering.
        if case .offline = link {} else { setLink(.connecting) }
        target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = devicePort.bigEndian
        #if canImport(Darwin)
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else {
            setLink(.offline("\(host) isn't an IP address. Type the switcher's address, such as 192.168.1.100"))
            return
        }
        #if canImport(Darwin)
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        #else
        let s = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #endif
        guard s >= 0 else { setLink(.offline("Couldn't open a network socket")); return }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = localPort.bigEndian
        #if canImport(Darwin)
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(s)
            setLink(.offline("Port \(localPort) on this computer is in use. Close AVMATRIX's control software (only one program can talk to the switcher)"))
            // Try again in a few seconds, in case it was closed.
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.fd == -1 { self?.open() } }
            return
        }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK)
        fd = s
        let r = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        r.setEventHandler { [weak self] in self?.read() }
        r.setCancelHandler { close(s) }
        r.resume()
        reader = r

        lastHeard = now()
        send(AVMatrixProtocol.frame(0xFE, [0x01]))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Once a second: a keep-alive and a request for the whole state, as AVMATRIX's own
    /// software does, and a check the switcher is still answering.
    private func tick() {
        send(AVMatrixProtocol.frame(0xFF, [0x01]))
        send(AVMatrixProtocol.frame(0xFE, [0x01]))
        if now() - lastHeard > 4 {
            heard = false
            setLink(.offline("No answer from \(host)"))
        }
    }

    private func send(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        var to = target
        _ = bytes.withUnsafeBytes { b in
            withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while fd >= 0 {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { return }
            // Only the switcher we're set up for.
            guard from.sin_addr.s_addr == target.sin_addr.s_addr else { continue }
            var s = status
            var report = false
            for f in AVMatrixProtocol.parse(Array(buf[0..<n])) where s.apply(f.command, f.data) { report = true }
            guard report else { continue }
            lastHeard = now()
            if !heard { heard = true; setLink(.online) }
            update(s)
        }
    }
}

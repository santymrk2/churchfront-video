import XCTest
import CueATEM
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The AVMATRIX protocol: frames checked byte for byte against ones confirmed on real
/// switchers (Bitfocus Companion module requests #936 and #1990), and the switcher's
/// state as the rest of the app sees it.
final class AVMatrixTests: XCTestCase {

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

    func testFramesMatchConfirmedOnes() {
        XCTAssertEqual(hex(AVMatrixProtocol.frame(0x11, [0x01, 0x00])), "5a 0c 00 00 00 00 03 11 01 00 7b dd")  // auto
        XCTAssertEqual(hex(AVMatrixProtocol.frame(0x12, [0x04, 0x00])), "5a 0c 00 00 00 00 03 12 04 00 7f dd")  // program
        XCTAssertEqual(hex(AVMatrixProtocol.frame(0x24, [0x01, 0x00, 0x00, 0x25])), "5a 0e 00 00 00 00 05 24 01 00 00 25 b7 dd")
        XCTAssertEqual(hex(AVMatrixProtocol.frame(0xFE, [0x01])), "5a 0b 00 00 00 00 02 fe 01 66 dd")  // sync
    }

    func testRequestsBecomeFrames() {
        XCTAssertEqual(AVMatrixProtocol.frame(for: .program(3, me: 0), ftb: false).map(hex), "5a 0b 00 00 00 00 02 12 03 7c dd")
        XCTAssertEqual(AVMatrixProtocol.frame(for: .preview(AVMatrixProtocol.patternSource, me: 0), ftb: false)?[8], 5)
        XCTAssertEqual(AVMatrixProtocol.frame(for: .cut(me: 0), ftb: false).map { Array($0[7...9]) }, [0x11, 0x02, 0x00])
        XCTAssertEqual(AVMatrixProtocol.frame(for: .fadeToBlack(me: 0), ftb: true).map { Array($0[8...9]) }, [0x03, 0x00])
        XCTAssertNil(AVMatrixProtocol.frame(for: .program(3, me: 1), ftb: false))  // there is no M/E 2
        XCTAssertNil(AVMatrixProtocol.frame(for: .program(9, me: 0), ftb: false))  // no input 9
        XCTAssertNil(AVMatrixProtocol.frame(for: .keyOnAir(keyer: 0, on: true, me: 0), ftb: false))
    }

    /// The app's switcher with an AVMATRIX driver, against a pretend switcher on this Mac.
    func testSwitcherRunsAPretendAVMATRIX() throws {
        let fake = try PretendAVMatrix()
        defer { fake.close() }
        let sw = Switcher()
        sw.connect("127.0.0.1", port: fake.port, kind: .avmatrix)
        defer { sw.disconnect() }
        XCTAssertTrue(wait(3) { sw.link == .online && sw.state.program[0] == 1 && sw.state.preview[0] == 2 })
        sw.setPreview(4)
        XCTAssertTrue(wait(2) { sw.state.preview[0] == 4 && sw.state.tally[4] == 2 })
        sw.auto()
        XCTAssertTrue(wait(2) { sw.state.program[0] == 4 && sw.state.tally[4] == 1 })
        XCTAssertTrue(wait(2) { fake.received.contains([0x13, 4]) && fake.received.contains([0x11, 1, 0]) })
        sw.setKeyOnAir(0, true)
        XCTAssertEqual(sw.sentLog.map(\.command), ["PVW", "AUTO", "KEY"])
        XCTAssertEqual(sw.sentLog.map(\.sent), [true, true, false])
    }

    private func wait(_ seconds: Double, _ until: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if until() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return until()
    }

    func testParsesFramesInOneDatagram() {
        let bytes = [0x00] + AVMatrixProtocol.frame(0x12, [2]) + AVMatrixProtocol.frame(0x13, [3])
        let f = AVMatrixProtocol.parse(bytes)
        XCTAssertEqual(f.map(\.command), [0x12, 0x13])
        XCTAssertEqual(f.map(\.data), [[2], [3]])
    }

    func testStateAndTally() {
        var st = AVMatrixStatus()
        st.apply(0x12, [1])
        st.apply(0x13, [5])
        st.apply(0x24, [6, 0, 50, 50])            // PIP 1 shows input 3
        st.apply(0x20, [0, 0, 2, 0, 0, 0])        // PIP 1 on air
        let s = st.atemState()
        XCTAssertEqual(s.program[0], 1)
        XCTAssertEqual(s.preview[0], AVMatrixProtocol.patternSource)
        XCTAssertEqual(s.tally[1], 1)
        XCTAssertEqual(s.tally[3], 1, "a camera in a PIP on air counts as Live")
        XCTAssertEqual(s.tally[2], 0)
        XCTAssertEqual(s.meCount, 1)
        XCTAssertEqual(s.keyerCount, 0)
        XCTAssertEqual(s.auxCount, 0)
    }
}

/// A pretend AVMATRIX on this Mac, on a port of its own: keeps program, preview and black,
/// answers a state request, and reports every change back to whoever sent the command.
private final class PretendAVMatrix {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var got: [[UInt8]] = []
    private var pgm: UInt8 = 1, pvw: UInt8 = 2, ftb: UInt8 = 0
    private var open = true

    /// Every command received, as the command byte followed by its data.
    var received: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return got }

    init() throws {
        #if canImport(Darwin)
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        #else
        let s = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #endif
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                bind(s, p, len) == 0 && getsockname(s, p, &len) == 0
            }
        }
        guard s >= 0, ok else { throw NSError(domain: "PretendAVMatrix", code: 1) }
        fd = s
        port = UInt16(bigEndian: a.sin_port)
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        Thread { [self] in self.run() }.start()
    }

    func close() { lock.lock(); open = false; lock.unlock() }

    private func run() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            lock.lock(); let still = open; lock.unlock()
            guard still else { break }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            for f in AVMatrixProtocol.parse(Array(buf[0..<n])) {
                lock.lock()
                got.append([f.command] + f.data)
                switch (f.command, f.data.first) {
                case (0x12, let v?): pgm = v
                case (0x13, let v?): pvw = v
                case (0x11, 0x01), (0x11, 0x02): (pgm, pvw) = (pvw, pgm)
                case (0x11, 0x03): ftb = f.data.count > 1 ? f.data[1] : 0
                default: break
                }
                let report = [AVMatrixProtocol.frame(0x12, [pgm]), AVMatrixProtocol.frame(0x13, [pvw]), AVMatrixProtocol.frame(0x11, [0x03, ftb])]
                lock.unlock()
                if f.command == 0xFF { continue }
                for r in report {
                    _ = r.withUnsafeBytes { b in
                        withUnsafePointer(to: &from) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, b.count, 0, $0, len) }
                        }
                    }
                }
            }
        }
        #if canImport(Darwin)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }
}

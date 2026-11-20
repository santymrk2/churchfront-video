import XCTest
import CueATEM

/// Switcher on its own, with a pretend driver: no network.
final class SwitcherTests: XCTestCase {

    private final class MockDriver: SwitcherDriver {
        let capabilities: SwitcherCapabilities
        var onEvent: ((SwitcherEvent) -> Void)?
        var accepts = true
        private(set) var started = false
        private(set) var stopped = false
        private(set) var performed: [SwitcherCommand] = []

        init(_ capabilities: SwitcherCapabilities) { self.capabilities = capabilities }
        func start() { started = true }
        func stop() { stopped = true }
        func perform(_ c: SwitcherCommand) -> Bool { performed.append(c); return accepts }
        /// As a real driver does: from a queue of its own.
        func emit(_ e: SwitcherEvent) { DispatchQueue.global().async { self.onEvent?(e) } }
    }

    private var made: [(kind: SwitcherKind, host: String, port: UInt16?, driver: MockDriver)] = []

    private func switcher(_ capabilities: SwitcherCapabilities = .all) -> Switcher {
        Switcher { [unowned self] kind, host, port in
            let d = MockDriver(capabilities)
            self.made.append((kind, host, port, d))
            return d
        }
    }

    override func setUp() { made = [] }

    private func wait(_ seconds: Double = 1, _ until: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if until() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return until()
    }

    func testConnectMakesAndStartsADriver() {
        let sw = switcher([.tbar])
        sw.connect(" 10.0.0.5 ", port: 1234, kind: .avmatrix)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].kind, .avmatrix)
        XCTAssertEqual(made[0].host, "10.0.0.5")
        XCTAssertEqual(made[0].port, 1234)
        XCTAssertTrue(made[0].driver.started)
        XCTAssertEqual(sw.host, "10.0.0.5")
        XCTAssertEqual(sw.kind, .avmatrix)
        XCTAssertEqual(sw.link, .connecting)
        XCTAssertEqual(sw.capabilities, [.tbar])
    }

    func testNoAddressMakesNoDriver() {
        let sw = switcher()
        sw.connect("  ")
        XCTAssertTrue(made.isEmpty)
        XCTAssertEqual(sw.link, .idle)
    }

    func testEventsReachTheApp() {
        let sw = switcher()
        sw.connect("10.0.0.5")
        var s = ATEMState()
        s.program[0] = 3
        made[0].driver.emit(.state(s))
        made[0].driver.emit(.link(.online))
        made[0].driver.emit(.transitionEnded(me: 0))
        XCTAssertTrue(wait { sw.state.program[0] == 3 && sw.link == .online && sw.tbarAtTop[0] == true })
    }

    func testAnEarlierConnectionIsStoppedAndIgnored() {
        let sw = switcher()
        sw.connect("10.0.0.5")
        sw.connect("10.0.0.6")
        XCTAssertTrue(made[0].driver.stopped)
        var old = ATEMState()
        old.program[0] = 9
        made[0].driver.emit(.state(old))
        made[0].driver.emit(.link(.offline("old")))
        var now = ATEMState()
        now.program[0] = 2
        made[1].driver.emit(.state(now))
        XCTAssertTrue(wait { sw.state.program[0] == 2 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(sw.state.program[0], 2)
        XCTAssertEqual(sw.link, .connecting)
    }

    func testCommandsTheSwitcherCantDoNeverReachIt() {
        let sw = switcher([])
        sw.connect("10.0.0.5")
        XCTAssertTrue(sw.cut())
        XCTAssertFalse(sw.setPosition(0.5))
        XCTAssertFalse(sw.setAux(0, 1))
        XCTAssertEqual(made[0].driver.performed, [.cut(me: 0)])
        XCTAssertEqual(sw.sentLog.map(\.command), ["CUT", "TBAR", "AUX"])
        XCTAssertEqual(sw.sentLog.map(\.sent), [true, false, false])
    }

    func testADriverThatDidntSendIsLoggedSo() {
        let sw = switcher()
        sw.connect("10.0.0.5")
        made[0].driver.accepts = false
        XCTAssertFalse(sw.setPreview(4))
        XCTAssertEqual(sw.sentLog.last?.sent, false)
        XCTAssertEqual(sw.sentLog.last?.describe(ATEMState()), "Preview, M/E 1: input 4")
    }

    func testDisconnect() {
        let sw = switcher()
        sw.connect("10.0.0.5")
        sw.disconnect()
        XCTAssertTrue(made[0].driver.stopped)
        XCTAssertEqual(sw.link, .idle)
        XCTAssertEqual(sw.capabilities, [])
        XCTAssertFalse(sw.cut())
    }

    func testTheLogKeepsTheLatest() {
        let sw = switcher()
        sw.connect("10.0.0.5")
        for i in 0..<75 { sw.setPreview(i) }
        XCTAssertEqual(sw.sentLog.count, 60)
        XCTAssertEqual(sw.sentLog.last?.request, .preview(74, me: 0))
    }

    func testEverySwitcherCanDoTheBasics() {
        for c: SwitcherCommand in [.program(1, me: 0), .preview(1, me: 0), .cut(me: 0), .auto(me: 0), .fadeToBlack(me: 0)] {
            XCTAssertEqual(c.requires, [], "\(c)")
        }
        XCTAssertEqual(SwitcherCommand.position(0.5, me: 0).requires, .tbar)
        XCTAssertEqual(SwitcherCapabilities([.tbar, .aux]).name, "a T-bar, aux outputs")
    }
}

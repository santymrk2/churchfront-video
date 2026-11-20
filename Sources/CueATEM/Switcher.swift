import Foundation
import Combine

// The switcher the app runs, whatever make it is. The app talks to one Switcher and reads
// one ATEMState; a driver per make (ATEMDriver, AVMatrixDriver) speaks to the hardware.
//
// ATEMState is the shared model, named for the ATEM because it was first and is the
// fullest: a make with less (one M/E, no aux, no keys) leaves those parts empty, and the
// app hides them.

/// The kinds of switcher there's a driver for.
public enum SwitcherKind: String, Codable, CaseIterable {
    /// Blackmagic ATEM, over UDP 9910.
    case atem
    /// AVMATRIX PVS0403U, HVS0403U and HVS0402U, over UDP 19523.
    case avmatrix

    public var title: String {
        switch self {
        case .atem: return "ATEM"
        case .avmatrix: return "AVMATRIX"
        }
    }

    func driver(host: String, port: UInt16?) -> SwitcherDriver {
        switch self {
        case .atem: return ATEMDriver(host: host, port: port ?? 9910)
        case .avmatrix: return AVMatrixDriver(host: host, devicePort: port ?? AVMatrixProtocol.devicePort)
        }
    }
}

public enum ATEMLink: Equatable {
    case idle
    case connecting
    case online
    case offline(String)
}

/// Something the app asks the switcher to do. M/Es, keyers, DSKs and aux outputs count
/// from 0; sources are ATEM-style input numbers (see ATEMInput).
public enum SwitcherCommand: Equatable {
    case program(Int, me: Int)
    case preview(Int, me: Int)
    case cut(me: Int)
    case auto(me: Int)
    /// The T-bar, 0 to 1 from the start of the transition.
    case position(Double, me: Int)
    /// 0 mix, 1 dip, 2 wipe, 3 DVE, 4 sting.
    case style(Int, me: Int)
    /// Bit 0 background, bit 1 key 1, bit 2 key 2 and so on.
    case nextSelection(Int, me: Int)
    case mixRate(frames: Int, me: Int)
    case keyOnAir(keyer: Int, on: Bool, me: Int)
    case dskOnAir(Int, on: Bool)
    case dskTie(Int, on: Bool)
    case dskAuto(Int)
    case fadeToBlack(me: Int)
    case aux(Int, source: Int)
    case runMacro(Int)
    case stopMacro
    case streaming(Bool)
    case recording(Bool)

    /// A short tag for the Status log.
    public var code: String {
        switch self {
        case .program: return "PGM"
        case .preview: return "PVW"
        case .cut: return "CUT"
        case .auto: return "AUTO"
        case .position: return "TBAR"
        case .style, .nextSelection: return "TRANS"
        case .mixRate: return "RATE"
        case .keyOnAir: return "KEY"
        case .dskOnAir, .dskAuto: return "DSK"
        case .dskTie: return "TIE"
        case .fadeToBlack: return "FTB"
        case .aux: return "AUX"
        case .runMacro, .stopMacro: return "MACRO"
        case .streaming: return "STREAM"
        case .recording: return "REC"
        }
    }

    /// A plain description, such as "Preview, M/E 1: Camera 1".
    public func describe(_ state: ATEMState) -> String {
        func src(_ id: Int) -> String { state.inputs[id]?.long ?? "input \(id)" }
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        switch self {
        case .program(let s, let me): return "Program, M/E \(me + 1): \(src(s))"
        case .preview(let s, let me): return "Preview, M/E \(me + 1): \(src(s))"
        case .cut(let me): return "Cut, M/E \(me + 1)"
        case .auto(let me): return "Auto transition, M/E \(me + 1)"
        case .position(let v, let me): return "T-bar, M/E \(me + 1): \(Int((v * 100).rounded()))%"
        case .style(_, let me), .nextSelection(_, let me): return "Transition settings, M/E \(me + 1)"
        case .mixRate(let f, let me): return "Mix rate, M/E \(me + 1): \(f) frames"
        case .keyOnAir(let k, let on, let me): return "Key \(k + 1) \(onOff(on)), M/E \(me + 1)"
        case .dskOnAir(let d, let on): return "DSK \(d + 1) \(onOff(on))"
        case .dskTie(let d, let on): return "DSK \(d + 1) tie \(onOff(on))"
        case .dskAuto(let d): return "DSK \(d + 1) auto"
        case .fadeToBlack(let me): return "Fade to black, M/E \(me + 1)"
        case .aux(let a, let s): return "Aux \(a + 1): \(src(s))"
        case .runMacro(let i): return "Run macro \(i + 1)"
        case .stopMacro: return "Stop macro"
        case .streaming(let on): return "Streaming \(on ? "start" : "stop")"
        case .recording(let on): return "Recording \(on ? "start" : "stop")"
        }
    }
}

/// What a driver reports, on its own queue.
public enum SwitcherEvent {
    case state(ATEMState)
    case link(ATEMLink)
    /// A transition on this M/E ended past halfway: the T-bar's rest end flips, as on a
    /// hardware panel.
    case transitionEnded(me: Int)
}

/// Speaks to one make of switcher. Each connection gets a new driver.
public protocol SwitcherDriver: AnyObject {
    var onEvent: ((SwitcherEvent) -> Void)? { get set }
    func start()
    func stop()
    /// Sends the command. False when it didn't go out: not connected, or this switcher
    /// has nothing like it.
    func perform(_ command: SwitcherCommand) -> Bool
}

public struct SwitcherLogEntry: Identifiable {
    public let id = UUID()
    public let time: Date
    public let request: SwitcherCommand
    /// False when it didn't go out: not connected, or the switcher has nothing like it.
    public let sent: Bool

    /// A short tag, such as PVW.
    public var command: String { request.code }
    public func describe(_ state: ATEMState) -> String { request.describe(state) }
}

public typealias ATEMLogEntry = SwitcherLogEntry

/// The switcher the app runs: what it shows, whether it's connected, and the commands sent.
public final class Switcher: ObservableObject {
    @Published public private(set) var state = ATEMState()
    @Published public private(set) var link: ATEMLink = .idle
    @Published public private(set) var host = ""
    @Published public private(set) var kind: SwitcherKind = .atem
    /// Which end of the T-bar is at rest, per M/E. Flips when a transition
    /// finishes, as on a hardware panel.
    @Published public private(set) var tbarAtTop: [Int: Bool] = [:]
    /// The last commands this app sent (or tried to send), newest last, for the Status window.
    @Published public private(set) var sentLog: [SwitcherLogEntry] = []

    private var driver: SwitcherDriver?

    public init() {}

    // MARK: Connection

    /// Connects to a switcher, dropping any earlier one. `port` is the switcher's own
    /// port, for tests; leave it out for the usual one.
    public func connect(_ host: String, port: UInt16? = nil, kind: SwitcherKind = .atem) {
        let h = host.trimmingCharacters(in: .whitespaces)
        driver?.stop()
        driver = nil
        self.host = h
        self.kind = kind
        state = ATEMState()
        link = h.isEmpty ? .idle : .connecting
        guard !h.isEmpty else { return }
        let d = kind.driver(host: h, port: port)
        d.onEvent = { [weak self, weak d] e in
            DispatchQueue.main.async {
                guard let self, let d, self.driver === d else { return }
                self.handle(e)
            }
        }
        driver = d
        d.start()
    }

    public func disconnect() {
        driver?.stop()
        driver = nil
        host = ""
        link = .idle
    }

    private func handle(_ e: SwitcherEvent) {
        switch e {
        case .state(let s): if state != s { state = s }
        case .link(let l): if link != l { link = l }
        case .transitionEnded(let me): tbarAtTop[me] = !(tbarAtTop[me] ?? false)
        }
    }

    // MARK: Commands

    public func perform(_ c: SwitcherCommand) {
        let ok = driver?.perform(c) ?? false
        let entry = SwitcherLogEntry(time: Date(), request: c, sent: ok)
        let log = {
            self.sentLog.append(entry)
            if self.sentLog.count > 60 { self.sentLog.removeFirst(self.sentLog.count - 60) }
        }
        if Thread.isMainThread { log() } else { DispatchQueue.main.async(execute: log) }
    }

    public func setProgram(_ source: Int, me: Int = 0) { perform(.program(source, me: me)) }
    public func setPreview(_ source: Int, me: Int = 0) { perform(.preview(source, me: me)) }
    public func cut(me: Int = 0) { perform(.cut(me: me)) }
    public func auto(me: Int = 0) { perform(.auto(me: me)) }
    /// 0 to 1 from the start of the transition.
    public func setPosition(_ v: Double, me: Int = 0) { perform(.position(min(1, max(0, v)), me: me)) }
    public func setStyle(_ style: Int, me: Int = 0) { perform(.style(style, me: me)) }
    public func setNextSelection(_ mask: Int, me: Int = 0) { perform(.nextSelection(max(1, mask), me: me)) }
    public func setMixRate(_ frames: Int, me: Int = 0) { perform(.mixRate(frames: min(250, max(1, frames)), me: me)) }
    public func setKeyOnAir(_ keyer: Int, _ on: Bool, me: Int = 0) { perform(.keyOnAir(keyer: keyer, on: on, me: me)) }
    public func setDSKOnAir(_ dsk: Int, _ on: Bool) { perform(.dskOnAir(dsk, on: on)) }
    public func setDSKTie(_ dsk: Int, _ on: Bool) { perform(.dskTie(dsk, on: on)) }
    public func dskAuto(_ dsk: Int) { perform(.dskAuto(dsk)) }
    public func fadeToBlack(me: Int = 0) { perform(.fadeToBlack(me: me)) }
    public func setAux(_ aux: Int, _ source: Int) { perform(.aux(aux, source: source)) }
    public func runMacro(_ index: Int) { perform(.runMacro(index)) }
    public func stopMacro() { perform(.stopMacro) }
    public func setStreaming(_ on: Bool) { perform(.streaming(on)) }
    public func setRecording(_ on: Bool) { perform(.recording(on)) }
}

/// The name the suite's apps (Churchfront Video, Screens, Cues) already use.
public typealias ATEMClient = Switcher

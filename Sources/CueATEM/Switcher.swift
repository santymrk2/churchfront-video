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

/// What a switcher can do beyond the basics every one has (program, preview, cut, auto
/// and fade to black). Each driver declares its own; the app hides, and Claude's tools
/// refuse, what isn't there.
public struct SwitcherCapabilities: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let tbar = SwitcherCapabilities(rawValue: 1 << 0)
    public static let transitionStyle = SwitcherCapabilities(rawValue: 1 << 1)
    public static let mixRate = SwitcherCapabilities(rawValue: 1 << 2)
    public static let nextTransition = SwitcherCapabilities(rawValue: 1 << 3)
    public static let upstreamKeys = SwitcherCapabilities(rawValue: 1 << 4)
    public static let downstreamKeys = SwitcherCapabilities(rawValue: 1 << 5)
    public static let aux = SwitcherCapabilities(rawValue: 1 << 6)
    public static let macros = SwitcherCapabilities(rawValue: 1 << 7)
    public static let streaming = SwitcherCapabilities(rawValue: 1 << 8)
    public static let recording = SwitcherCapabilities(rawValue: 1 << 9)

    public static let all: SwitcherCapabilities = [.tbar, .transitionStyle, .mixRate, .nextTransition, .upstreamKeys,
                                                   .downstreamKeys, .aux, .macros, .streaming, .recording]

    /// In plain words, for messages: "a T-bar", "aux outputs".
    public var name: String {
        let names: [(SwitcherCapabilities, String)] = [
            (.tbar, "a T-bar"), (.transitionStyle, "transition styles"), (.mixRate, "a mix rate"),
            (.nextTransition, "next-transition selection"), (.upstreamKeys, "upstream keys"),
            (.downstreamKeys, "downstream keys"), (.aux, "aux outputs"), (.macros, "macros"),
            (.streaming, "streaming"), (.recording, "recording"),
        ]
        return names.filter { contains($0.0) }.map(\.1).joined(separator: ", ")
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

    /// What the switcher needs to be able to do for this; empty for the basics.
    public var requires: SwitcherCapabilities {
        switch self {
        case .program, .preview, .cut, .auto, .fadeToBlack: return []
        case .position: return .tbar
        case .style: return .transitionStyle
        case .mixRate: return .mixRate
        case .nextSelection: return .nextTransition
        case .keyOnAir: return .upstreamKeys
        case .dskOnAir, .dskTie, .dskAuto: return .downstreamKeys
        case .aux: return .aux
        case .runMacro, .stopMacro: return .macros
        case .streaming: return .streaming
        case .recording: return .recording
        }
    }

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
    /// What this switcher can do beyond the basics. Switcher only passes on commands it covers.
    var capabilities: SwitcherCapabilities { get }
    /// Set before start. Called on the driver's own queue.
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

    public init(time: Date, request: SwitcherCommand, sent: Bool) {
        self.time = time
        self.request = request
        self.sent = sent
    }

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
    /// What the connected switcher can do beyond the basics.
    @Published public private(set) var capabilities: SwitcherCapabilities = []

    public typealias DriverFactory = (_ kind: SwitcherKind, _ host: String, _ port: UInt16?) -> SwitcherDriver

    private let makeDriver: DriverFactory
    private var driver: SwitcherDriver?
    private static let logLength = 60

    public convenience init() {
        self.init { kind, host, port in kind.driver(host: host, port: port) }
    }

    /// `makeDriver` makes the driver for each connection; tests pass their own.
    public init(makeDriver: @escaping DriverFactory) {
        self.makeDriver = makeDriver
    }

    /// Whether the connected switcher can do this.
    public func supports(_ c: SwitcherCommand) -> Bool { capabilities.isSuperset(of: c.requires) }

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
        capabilities = []
        link = h.isEmpty ? .idle : .connecting
        guard !h.isEmpty else { return }
        let d = makeDriver(kind, h, port)
        d.onEvent = { [weak self, weak d] e in
            DispatchQueue.main.async {
                guard let self, let d, self.driver === d else { return }
                self.handle(e)
            }
        }
        driver = d
        capabilities = d.capabilities
        d.start()
    }

    public func disconnect() {
        driver?.stop()
        driver = nil
        host = ""
        capabilities = []
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

    /// Sends a request. True if it went out; false if the switcher isn't connected or
    /// can't do it (it never reaches a driver that can't), and either way it's logged.
    @discardableResult
    public func perform(_ c: SwitcherCommand) -> Bool {
        let ok = supports(c) && (driver?.perform(c) ?? false)
        let entry = SwitcherLogEntry(time: Date(), request: c, sent: ok)
        let log = {
            self.sentLog.append(entry)
            if self.sentLog.count > Self.logLength { self.sentLog.removeFirst(self.sentLog.count - Self.logLength) }
        }
        if Thread.isMainThread { log() } else { DispatchQueue.main.async(execute: log) }
        return ok
    }

    @discardableResult public func setProgram(_ source: Int, me: Int = 0) -> Bool { perform(.program(source, me: me)) }
    @discardableResult public func setPreview(_ source: Int, me: Int = 0) -> Bool { perform(.preview(source, me: me)) }
    @discardableResult public func cut(me: Int = 0) -> Bool { perform(.cut(me: me)) }
    @discardableResult public func auto(me: Int = 0) -> Bool { perform(.auto(me: me)) }
    /// 0 to 1 from the start of the transition.
    @discardableResult public func setPosition(_ v: Double, me: Int = 0) -> Bool { perform(.position(min(1, max(0, v)), me: me)) }
    @discardableResult public func setStyle(_ style: Int, me: Int = 0) -> Bool { perform(.style(style, me: me)) }
    @discardableResult public func setNextSelection(_ mask: Int, me: Int = 0) -> Bool { perform(.nextSelection(max(1, mask), me: me)) }
    @discardableResult public func setMixRate(_ frames: Int, me: Int = 0) -> Bool { perform(.mixRate(frames: min(250, max(1, frames)), me: me)) }
    @discardableResult public func setKeyOnAir(_ keyer: Int, _ on: Bool, me: Int = 0) -> Bool { perform(.keyOnAir(keyer: keyer, on: on, me: me)) }
    @discardableResult public func setDSKOnAir(_ dsk: Int, _ on: Bool) -> Bool { perform(.dskOnAir(dsk, on: on)) }
    @discardableResult public func setDSKTie(_ dsk: Int, _ on: Bool) -> Bool { perform(.dskTie(dsk, on: on)) }
    @discardableResult public func dskAuto(_ dsk: Int) -> Bool { perform(.dskAuto(dsk)) }
    @discardableResult public func fadeToBlack(me: Int = 0) -> Bool { perform(.fadeToBlack(me: me)) }
    @discardableResult public func setAux(_ aux: Int, _ source: Int) -> Bool { perform(.aux(aux, source: source)) }
    @discardableResult public func runMacro(_ index: Int) -> Bool { perform(.runMacro(index)) }
    @discardableResult public func stopMacro() -> Bool { perform(.stopMacro) }
    @discardableResult public func setStreaming(_ on: Bool) -> Bool { perform(.streaming(on)) }
    @discardableResult public func setRecording(_ on: Bool) -> Bool { perform(.recording(on)) }
}

/// The name the suite's apps (Churchfront Video, Screens, Cues) already use.
public typealias ATEMClient = Switcher

import AppKit
import CueATEM
import NDIBridge

/// CUEVIDEO_SELFTEST=1 with CUEVIDEO_HOST pointed at a switcher (or Tools/fake_atem.py):
/// waits for the switcher, runs every command, prints the state after each,
/// writes window snapshots to CUEVIDEO_SNAPSHOT (a folder), and quits.
/// Never point it at a switcher that is live on a service.
enum SelfTest {
    /// With CUEVIDEO_FAKECAMS: once Tools/FakeCamera sends "Fake PTZ 1", "Fake PTZ 2" or
    /// "Fake PTZ 3", that becomes the picture of the pretend camera on input 1, 2 or 3, so
    /// auto tracking can run on it. Looks every few seconds; nothing is saved.
    static func watchFakeCameraPictures(_ store: ConfigStore) {
        DispatchQueue.global(qos: .utility).async {
            guard ndi_load() != nil else { return }
            var buf = [CChar](repeating: 0, count: 256 * 64)
            while true {
                let n = Int(ndi_sources(&buf, 64, 3000))
                let names = (0..<n).map { i in buf.withUnsafeBufferPointer { String(cString: $0.baseAddress! + i * 256) } }
                DispatchQueue.main.async {
                    for input in 1...3 {
                        guard let name = names.first(where: { $0.hasSuffix("(Fake PTZ \(input))") }), store.ndi(input) != name else { continue }
                        store.setPicture(input, name)
                    }
                }
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    /// CUEVIDEO_PROBE=1: connect, read everything, print it, snapshot, quit. Sends no commands,
    /// so it is safe on a real switcher.
    static func probe() {
        let atem = Booth.shared.atem
        let out = ProcessInfo.processInfo.environment["CUEVIDEO_SNAPSHOT"]
        func log(_ s: String) { print("PROBE", s); fflush(stdout) }
        func check() {
            guard atem.link == .online, !atem.state.inputs.isEmpty else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check); return
            }
            // Give the rest of the state dump a moment to arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let s = atem.state
                log("switcher: \(s.product), protocol \(s.version), M/Es \(s.meCount), keyers \(s.keyerCount), DSKs \(s.dskCount), aux \(s.auxCount)")
                for i in s.inputs.values.sorted(by: { $0.id < $1.id }) {
                    log("input \(i.id) \(i.short) | \(i.long)\(i.isBusSource ? "" : " (not on bus)")")
                }
                for me in 0..<s.meCount {
                    log("M/E \(me + 1): program \(s.name(s.program[me])), preview \(s.name(s.preview[me])), style \(s.style[me] ?? -1), next \(s.nextSelection[me] ?? -1), mix rate \(s.mixRate[me] ?? -1), in transition \(s.inTransition[me] ?? false), keys on air \(s.keyOnAir[me] ?? [:]), FTB \(s.ftbBlack[me] ?? false)")
                }
                log("DSK on air \(s.dskOnAir), tie \(s.dskTie)")
                log("aux \(s.aux.keys.sorted().map { "\($0 + 1)=\(s.name(s.aux[$0]))" })")
                log("macros \(s.macros.keys.sorted().map { "\($0 + 1)=\(s.macros[$0]!)" })")
                log("stream status \(s.streamStatus), record status \(s.recordStatus), tally entries \(s.tally.count)")
                if let out, let v = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("probe.png"))
                    log("snapshot probe.png")
                }
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { log("no switcher: \(atem.link)"); exit(1) }
    }

    /// CUEVIDEO_REALTEST=1: every command on a real switcher, one at a time, each checked
    /// against what the switcher reports back, then everything put back as it was.
    /// Only when nothing is live.
    static func realTest() {
        let atem = Booth.shared.atem
        guard atem.kind == .atem else {
            print("This self-test runs ATEM commands. For an AVMATRIX: swift test, and Tools/fake_avmatrix.py with the app.")
            exit(2)
        }
        let only = ProcessInfo.processInfo.environment["CUEVIDEO_REALTEST"] == "trace"
        func log(_ s: String) { print("REAL", s); fflush(stdout) }
        var passed = 0, failed = 0
        typealias Step = (name: String, wait: Double, act: () -> Void, check: (ATEMState) -> Bool)
        var steps: [Step] = []

        func begin() {
            let s = atem.state
            let p1 = s.program[0] ?? 0, v1 = s.preview[0] ?? 0, v2 = s.preview[1] ?? 0
            let style = s.style[0] ?? 0, rate = s.mixRate[0] ?? 30, sel = s.nextSelection[0] ?? 1
            let tie2 = s.dskTie[1] ?? false, key2 = s.keyOnAir[1]?[1] ?? false
            let aux12 = s.aux[11] ?? 10010
            let camA = s.inputs[9] != nil ? 9 : (s.busSources.first { $0.isExternal }?.id ?? 1)
            let camB = s.inputs[10] != nil ? 10 : camA
            log("start: M/E1 program \(s.name(p1)) preview \(s.name(v1)); M/E2 preview \(s.name(v2))")
            steps = [
                ("M/E 1 auto (trace)", Double(rate) / 30 + 0.8, { atem.auto(me: 0) }, { $0.program[0] != p1 }),
                ("M/E 1 auto back (trace)", Double(rate) / 30 + 0.8, { atem.auto(me: 0) }, { $0.program[0] == p1 }),
                ("fade to black (trace)", 3, { atem.fadeToBlack(me: 0) }, { $0.ftbBlack[0] == true }),
                ("fade back up (trace)", 3, { atem.fadeToBlack(me: 0) }, { $0.ftbBlack[0] == false }),
                ("M/E 2 preview to \(s.name(camB))", 0.5, { atem.setPreview(camB, me: 1) }, { $0.preview[1] == camB }),
                ("M/E 2 preview back", 0.5, { atem.setPreview(v2, me: 1) }, { $0.preview[1] == v2 }),
                ("M/E 1 preview to \(s.name(camA))", 0.5, { atem.setPreview(camA, me: 0) }, { $0.preview[0] == camA }),
                ("M/E 1 cut", 0.6, { atem.cut(me: 0) }, { $0.program[0] == camA && $0.preview[0] == p1 }),
                ("M/E 1 cut back", 0.6, { atem.cut(me: 0) }, { $0.program[0] == p1 && $0.preview[0] == camA }),
                ("M/E 1 auto", Double(rate) / 30 + 0.8, { atem.auto(me: 0) }, { $0.program[0] == camA && $0.inTransition[0] != true }),
                ("M/E 1 auto back", Double(rate) / 30 + 0.8, { atem.auto(me: 0) }, { $0.program[0] == p1 && $0.inTransition[0] != true }),
                ("T-bar halfway", 0.6, { atem.setPosition(0.5, me: 0) }, { $0.inTransition[0] == true }),
                ("T-bar all the way", 0.8, { atem.setPosition(1.0, me: 0) }, { $0.program[0] == camA && $0.inTransition[0] != true }),
                ("cut back after T-bar", 0.6, { atem.cut(me: 0) }, { $0.program[0] == p1 }),
                ("preview back", 0.5, { atem.setPreview(v1, me: 0) }, { $0.preview[0] == v1 }),
                ("style dip", 0.5, { atem.setStyle(1, me: 0) }, { $0.style[0] == 1 }),
                ("style back", 0.5, { atem.setStyle(style, me: 0) }, { $0.style[0] == style }),
                ("mix rate +5", 0.5, { atem.setMixRate(rate + 5, me: 0) }, { $0.mixRate[0] == rate + 5 }),
                ("mix rate back", 0.5, { atem.setMixRate(rate, me: 0) }, { $0.mixRate[0] == rate }),
                ("next transition adds key 2", 0.5, { atem.setNextSelection(sel ^ 4, me: 0) }, { $0.nextSelection[0] == sel ^ 4 }),
                ("next transition back", 0.5, { atem.setNextSelection(sel, me: 0) }, { $0.nextSelection[0] == sel }),
                ("M/E 2 key 2 on air", 0.5, { atem.setKeyOnAir(1, !key2, me: 1) }, { $0.keyOnAir[1]?[1] == !key2 }),
                ("M/E 2 key 2 back", 0.5, { atem.setKeyOnAir(1, key2, me: 1) }, { $0.keyOnAir[1]?[1] == key2 }),
                ("DSK 2 tie", 0.5, { atem.setDSKTie(1, !tie2) }, { $0.dskTie[1] == !tie2 }),
                ("DSK 2 tie back", 0.5, { atem.setDSKTie(1, tie2) }, { $0.dskTie[1] == tie2 }),
                ("aux 12 to M/E 1 preview", 0.5, { atem.setAux(11, 10011) }, { $0.aux[11] == 10011 }),
                ("aux 12 back", 0.5, { atem.setAux(11, aux12) }, { $0.aux[11] == aux12 }),
                ("fade to black", 2.2, { atem.fadeToBlack(me: 0) }, { $0.ftbBlack[0] == true && $0.ftbInTransition[0] != true }),
                ("fade back up", 2.2, { atem.fadeToBlack(me: 0) }, { $0.ftbBlack[0] == false && $0.ftbInTransition[0] != true }),
            ]
            if only { steps = Array(steps.prefix(4)) } else { steps.removeFirst(4) }
            step(0)
        }
        func step(_ i: Int) {
            guard i < steps.count else {
                let s = atem.state
                log("end: M/E1 program \(s.name(s.program[0])) preview \(s.name(s.preview[0])); M/E2 preview \(s.name(s.preview[1]))")
                log("\(passed) passed, \(failed) failed")
                exit(failed == 0 ? 0 : 1)
            }
            let st = steps[i]
            st.act()
            DispatchQueue.main.asyncAfter(deadline: .now() + st.wait) {
                let ok = st.check(atem.state)
                if ok { passed += 1 } else { failed += 1 }
                let a = atem.state
                log("\(ok ? "PASS" : "FAIL") \(st.name)" + (ok ? "" : "  [program \(a.name(a.program[0])) preview \(a.name(a.preview[0])) in transition \(a.inTransition[0] ?? false) black \(a.ftbBlack[0] ?? false) fading \(a.ftbInTransition[0] ?? false)]"))
                step(i + 1)
            }
        }
        func wait() {
            if atem.link == .online && !atem.state.inputs.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: begin)
            } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: wait) }
        }
        wait()
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { log("timed out"); exit(1) }
    }

    /// CUEVIDEO_PTZTEST=ip,ip: adds those Canon cameras (not saved), then on each one waits for it,
    /// prints its model and presets, and nudges pan, tilt and zoom through the app's own controls.
    /// Record positions before and put them back after (Tools/canon_position.py).
    static func ptzTest(_ list: String) {
        let ptz = Booth.shared.ptz
        func log(_ s: String) { print("PTZ", s); fflush(stdout) }
        var cams: [PTZCamera] = []
        for ip in list.split(separator: ",") {
            var c = PTZCamera(); c.name = String(ip); c.host = String(ip); c.proto = .canonXC; c.port = 80
            cams.append(c)
        }
        ptz.cameras = cams
        let moves: [(String, Double, () -> Void)] = [
            ("pan right", 0.4, { ptz.drive(x: 0.4, y: 0) }), ("stop", 0.5, { ptz.stopDrive() }),
            ("pan left", 0.4, { ptz.drive(x: -0.4, y: 0) }), ("stop", 0.5, { ptz.stopDrive() }),
            ("tilt up", 0.4, { ptz.drive(x: 0, y: 0.4) }), ("stop", 0.5, { ptz.stopDrive() }),
            ("tilt down", 0.4, { ptz.drive(x: 0, y: -0.4) }), ("stop", 0.5, { ptz.stopDrive() }),
            ("zoom in", 0.4, { ptz.zoom(0.5) }), ("zoom stop", 0.5, { ptz.zoom(0) }),
            ("zoom out", 0.4, { ptz.zoom(-0.5) }), ("zoom stop", 0.5, { ptz.zoom(0) }),
        ]
        func camera(_ i: Int) {
            guard i < cams.count else { log("done"); ptz.cameras = []; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }; return }
            let c = cams[i]
            ptz.selected = c.id
            var waited = 0.0
            func ready() {
                if ptz.online.contains(c.id) && ptz.models[c.id] != nil {
                    log("\(c.host): \(ptz.models[c.id]!), presets \(ptz.presetNames(c).keys.sorted().map { "\($0)=\(ptz.presetNames(c)[$0]!)" })")
                    move(0)
                } else if waited > 8 {
                    log("\(c.host): no answer"); camera(i + 1)
                } else { waited += 0.25; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: ready) }
            }
            func move(_ m: Int) {
                guard m < moves.count else {
                    if let first = ptz.presetNames(c).keys.sorted().first {
                        log("\(c.host): recall preset \(first)"); ptz.recall(first)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { camera(i + 1) }
                    } else { camera(i + 1) }
                    return
                }
                moves[m].2()
                DispatchQueue.main.asyncAfter(deadline: .now() + moves[m].1) { log("\(c.host): \(moves[m].0) sent"); move(m + 1) }
            }
            ready()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { camera(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { log("timed out"); exit(1) }
    }

    /// CUEVIDEO_FOLLOWTEST=1: puts each linked camera's input on M/E 1 preview (never program),
    /// checks "Follow next" selects that camera, then puts preview back.
    static func followTest() {
        let booth = Booth.shared, atem = booth.atem, ptz = booth.ptz
        func log(_ s: String) { print("FOLLOW", s); fflush(stdout) }
        booth.followPreview = true
        func wait() {
            guard atem.link == .online, !atem.state.inputs.isEmpty else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: wait); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let original = atem.state.preview[0] ?? 0
                let cams = ptz.cameras.filter { $0.atemInput != nil }
                var fails = 0
                func step(_ i: Int) {
                    guard i < cams.count else {
                        atem.setPreview(original, me: 0)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            log("preview back to \(atem.state.name(atem.state.preview[0])); \(cams.count - fails) of \(cams.count) passed")
                            exit(fails == 0 ? 0 : 1)
                        }
                        return
                    }
                    let c = cams[i]
                    atem.setPreview(c.atemInput!, me: 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let ok = ptz.selected == c.id
                        if !ok { fails += 1 }
                        log("\(ok ? "PASS" : "FAIL") preview \(atem.state.name(atem.state.preview[0])) selects \(ptz.current?.name ?? "none") (want \(c.name))")
                        step(i + 1)
                    }
                }
                step(cams.count > 1 ? 0 : 0)
            }
        }
        wait()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { log("timed out"); exit(1) }
    }

    static func run() {
        let booth = Booth.shared
        let atem = booth.atem
        guard atem.kind == .atem else {
            print("This self-test runs ATEM commands. For an AVMATRIX: swift test, and Tools/fake_avmatrix.py with the app.")
            exit(2)
        }
        let ptz = booth.ptz
        let out = ProcessInfo.processInfo.environment["CUEVIDEO_SNAPSHOT"]
        func log(_ s: String) { print("SELFTEST", s); fflush(stdout) }
        func summary() -> String {
            let s = atem.state
            return "pgm=\(s.name(s.program[0])) pvw=\(s.name(s.preview[0])) trans=\(s.inTransition[0] ?? false) style=\(s.style[0] ?? -1) next=\(s.nextSelection[0] ?? -1) key1=\(s.keyOnAir[0]?[0] ?? false) dsk1=\(s.dskOnAir[0] ?? false) tie1=\(s.dskTie[0] ?? false) ftb=\(s.ftbBlack[0] ?? false) aux1=\(s.name(s.aux[0])) macro=\(s.macroRunning.map(String.init) ?? "-") stream=\(s.streamStatus) rec=\(s.recordStatus) rate=\(s.mixRate[0] ?? -1) tbarTop=\(atem.tbarAtTop[0] ?? false)"
        }
        func snap(_ name: String) {
            guard let out, let v = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".png"))
            log("snapshot \(name).png")
        }
        let steps: [(String, Double, () -> Void)] = [
            ("connected", 0, {}),
            ("preview 3", 0.5, { atem.setPreview(3) }),
            ("cut", 0.5, { atem.cut() }),
            ("preview 4", 0.5, { atem.setPreview(4) }),
            // Caught mid-fade, so the snapshot shows Next coming in over Live. The next
            // step's auto is ignored while this one runs, and then waits for it to finish.
            ("fade halfway", 0.5, { atem.auto() }),
            ("auto", 1.6, { atem.auto() }),
            ("style dip", 0.4, { atem.setStyle(1) }),
            ("next bkgd+key1", 0.4, { atem.setNextSelection(3) }),
            ("mix rate 45", 0.4, { atem.setMixRate(45) }),
            ("key 1 on", 0.4, { atem.setKeyOnAir(0, true) }),
            ("dsk 1 tie", 0.4, { atem.setDSKTie(0, true) }),
            ("dsk 1 auto", 1.2, { atem.dskAuto(0) }),
            ("aux 1 cam 1", 0.4, { atem.setAux(0, 1) }),
            ("macro 1", 0.3, { atem.runMacro(0) }),
            ("stream on", 1.5, { atem.setStreaming(true) }),
            ("record on", 0.4, { atem.setRecording(true) }),
            ("tbar half", 0.4, { atem.setPosition(0.5) }),
            ("tbar full", 0.6, { atem.setPosition(1.0) }),
            ("ptz drive", 0.3, { ptz.drive(x: 0.5, y: 0.5) }),
            ("ptz stop", 0.3, { ptz.stopDrive() }),
            ("ptz zoom in", 0.3, { ptz.zoom(1) }),
            ("ptz zoom stop", 0.3, { ptz.zoom(0) }),
            ("ptz recall 2", 0.3, { ptz.recall(2) }),
            ("ptz store 3", 0.3, { ptz.store(3) }),
            ("follow preview cam 2", 0.5, { atem.setPreview(2) }),
        ]
        func wait() {
            if atem.link == .online && !atem.state.inputs.isEmpty {
                log("online: \(atem.state.product), \(atem.state.inputs.count) inputs, \(atem.state.macros.count) macros")
                snap("full")
                step(0)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: wait)
            }
        }
        func step(_ i: Int) {
            guard i < steps.count else {
                log("selected camera: \(ptz.current?.name ?? "none")")
                snap("full-after")
                booth.simple = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    snap("simple")
                    booth.simple = false
                    log("done")
                    exit(0)
                }
                return
            }
            let (name, delay, action) = steps[i]
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, delay)) {
                log("\(name): \(summary())")
                if name == "fade halfway" { snap("fade-halfway") }
                step(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: wait)
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { log("timed out: \(atem.link)"); exit(1) }
    }
}

import SwiftUI
import CueATEM

/// The switcher panel: program and preview rows with the transition block beside them,
/// then keys, macros and aux outputs below. Rows wrap to fit the page, so nothing is cut off.
struct SurfaceView: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var me: Int = 0
    var st: ATEMState { atem.state }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s4) {
            HStack(alignment: .top, spacing: T.s4) {
                Card {
                    bus("Program", st.program[me], T.program) { atem.setProgram($0, me: me) }
                    bus("Preview", st.preview[me], T.preview) { atem.setPreview($0, me: me) }
                }
                Card(title: "Transition") { transition }.fixedSize()
            }
            HStack(alignment: .top, spacing: T.s4) {
                if (st.keyerCount > 0 && atem.capabilities.contains(.upstreamKeys))
                    || (st.dskCount > 0 && atem.capabilities.contains(.downstreamKeys)) {
                    Card(title: "Keys") { keys }.fixedSize()
                }
                if !st.macros.isEmpty {
                    Card(title: "Macros") { macros }
                }
            }
            if st.auxCount > 0 {
                Card(title: "Aux outputs", help: "The same outputs as the Routing page, by number. Routing shows them by the screen each one feeds.") { aux }
            }
        }
    }

    // MARK: Buses

    func bus(_ label: String, _ selected: Int?, _ color: Color, _ pick: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).panelLabel(color)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 76), spacing: T.s2)], alignment: .leading, spacing: T.s2) {
                ForEach(st.busSources) { s in
                    PanelButton(title: s.short, lit: s.id == selected ? color : nil, width: 76, height: 52, titleSize: 14) { pick(s.id) }
                        .help(s.long)
                }
            }
        }
    }

    // MARK: Keys

    var keys: some View {
        HStack(alignment: .top, spacing: T.s5) {
            if st.keyerCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next transition takes").font(.sans(11)).foregroundStyle(T.inkSubtle)
                    let sel = st.nextSelection[me] ?? 1
                    HStack(spacing: T.s2) {
                        PanelButton(title: "BKGD", lit: sel & 1 != 0 ? T.warning : nil, width: 62, height: 40, titleSize: 12) {
                            atem.setNextSelection(sel ^ 1, me: me)
                        }
                        ForEach(0..<st.keyerCount, id: \.self) { k in
                            PanelButton(title: "KEY \(k + 1)", lit: sel & (2 << k) != 0 ? T.warning : nil, width: 62, height: 40, titleSize: 12) {
                                atem.setNextSelection(sel ^ (2 << k), me: me)
                            }
                        }
                    }
                    Text("On air").font(.sans(11)).foregroundStyle(T.inkSubtle).padding(.top, T.s2)
                    HStack(spacing: T.s2) {
                        ForEach(0..<st.keyerCount, id: \.self) { k in
                            let on = st.keyOnAir[me]?[k] ?? false
                            PanelButton(title: "KEY \(k + 1)", lit: on ? T.program : nil, width: 62, height: 40, titleSize: 12) {
                                atem.setKeyOnAir(k, !on, me: me)
                            }
                        }
                    }
                }
            }
            ForEach(0..<st.dskCount, id: \.self) { d in
                VStack(spacing: T.s2) {
                    Text("DSK \(d + 1)").font(.sans(11)).foregroundStyle(T.inkSubtle)
                    PanelButton(title: "TIE", lit: st.dskTie[d] == true ? T.warning : nil, width: 62, height: 34, titleSize: 12) {
                        atem.setDSKTie(d, !(st.dskTie[d] ?? false))
                    }
                    PanelButton(title: "CUT", lit: st.dskOnAir[d] == true ? T.program : nil, width: 62, height: 34, titleSize: 12) {
                        atem.setDSKOnAir(d, !(st.dskOnAir[d] ?? false))
                    }
                    PanelButton(title: "AUTO", lit: st.dskInTransition[d] == true ? T.program : nil, width: 62, height: 34, titleSize: 12,
                                blink: st.dskInTransition[d] == true) {
                        atem.dskAuto(d)
                    }
                }
            }
        }
    }

    // MARK: Macros and aux

    var macros: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: T.s2)], alignment: .leading, spacing: T.s2) {
                ForEach(st.macros.keys.sorted(), id: \.self) { i in
                    PanelButton(title: st.macros[i] ?? "", subtitle: "\(i + 1)", lit: st.macroRunning == i ? T.warning : nil,
                                width: 110, height: 40, titleSize: 12, blink: st.macroRunning == i) { atem.runMacro(i) }
                }
            }
            if st.macroRunning != nil {
                Button("Stop the macro") { atem.stopMacro() }.buttonStyle(CueButton(kind: .danger))
            }
        }
    }

    var aux: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: T.s3, alignment: .top)], alignment: .leading, spacing: T.s3) {
            ForEach(st.aux.keys.sorted(), id: \.self) { a in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Aux \(a + 1)").font(.sans(11, .bold)).foregroundStyle(T.inkMuted)
                        if let name = store.screen(aux: a + 1)?.name { Text(name).font(.sans(11)).foregroundStyle(T.inkSubtle).lineLimit(1) }
                    }
                    MenuField(text: st.inputs[st.aux[a] ?? 0]?.long ?? "Input \(st.aux[a] ?? 0)") {
                        ForEach(st.auxSources) { s in Button(s.long) { atem.setAux(a, s.id) } }
                    }
                }
            }
        }
    }

    // MARK: Transition block

    var transition: some View {
        let inT = st.inTransition[me] ?? false
        let black = st.ftbBlack[me] ?? false
        let can = atem.capabilities
        return HStack(alignment: .top, spacing: T.s4) {
            if can.contains(.transitionStyle) || can.contains(.mixRate) {
                VStack(spacing: T.s2) {
                    if can.contains(.transitionStyle) {
                        ForEach([(0, "MIX"), (1, "DIP"), (2, "WIPE"), (3, "DVE")], id: \.0) { id, name in
                            PanelButton(title: name, lit: (st.style[me] ?? 0) == id ? T.warning : nil, width: 62, height: 32, titleSize: 11) {
                                atem.setStyle(id, me: me)
                            }
                        }
                    }
                    if can.contains(.mixRate) {
                        HStack(spacing: 2) {
                            IconButton(icon: "minus", help: "Shorter mix") { atem.setMixRate((st.mixRate[me] ?? 30) - 5, me: me) }
                            Text(rate(st.mixRate[me] ?? 30)).font(.sans(12, .semibold)).frame(width: 34)
                            IconButton(icon: "plus", help: "Longer mix") { atem.setMixRate((st.mixRate[me] ?? 30) + 5, me: me) }
                        }
                        .help("Mix length in seconds and frames")
                    }
                }
            }
            VStack(spacing: T.s2) {
                PanelButton(title: "CUT", width: 84, height: 52, titleSize: 15) { atem.cut(me: me) }
                PanelButton(title: "AUTO", lit: inT ? T.program : nil, width: 84, height: 52, titleSize: 15) { atem.auto(me: me) }
                PanelButton(title: "FTB", lit: black || (st.ftbInTransition[me] ?? false) ? T.program : nil,
                            width: 84, height: 36, titleSize: 12, blink: black) { atem.fadeToBlack(me: me) }
                    .help("Fade to black")
            }
            if can.contains(.tbar) {
                TBar(me: me).frame(width: 56, height: 170)
            }
        }
    }

    func rate(_ frames: Int) -> String { "\(frames / 30):\(String(format: "%02d", frames % 30))" }
}

/// A T-bar you drag like the real lever. Its rest end flips after each transition.
struct TBar: View {
    @EnvironmentObject var atem: ATEMClient
    let me: Int
    @State private var dragging: Double?

    var body: some View {
        let atTop = atem.tbarAtTop[me] ?? false
        let pos = atem.state.position[me] ?? 0
        let inT = atem.state.inTransition[me] ?? false
        // Knob height above the bottom, 0 to 1.
        let shown = dragging ?? (inT ? (atTop ? 1 - pos : pos) : (atTop ? 1 : 0))
        return GeometryReader { g in
            let knob: CGFloat = 26
            let travel = g.size.height - knob
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(T.surface).overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line))
                RoundedRectangle(cornerRadius: 2).fill(T.surfaceSunken).frame(width: 6).padding(.vertical, 10)
                RoundedRectangle(cornerRadius: 4).fill(inT ? T.program : T.inkMuted)
                    .overlay(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.25)).frame(height: 2))
                    .frame(width: g.size.width - 8, height: knob)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .offset(y: (1 - shown) * travel)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = min(1, max(0, 1 - (v.location.y - knob / 2) / travel))
                dragging = f
                atem.setPosition(atTop ? 1 - f : f, me: me)
            }.onEnded { _ in dragging = nil })
        }
    }
}

import SwiftUI
import CueATEM

struct ContentView: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Rectangle().fill(T.line).frame(height: 1)
            if booth.view == .engineer {
                // Reachable before the switcher is found too: Setup is where its address goes.
                EngineerView()
                    .overlay(alignment: .top) { VStack(spacing: 0) { LinkBanner(); ConfigBanner() } }
            } else if booth.connectedOnce || atem.link == .online {
                VolunteerView()
                    .overlay(alignment: .top) { VStack(spacing: 0) { LinkBanner(); ConfigBanner() } }
            } else {
                ConnectView()
            }
        }
        .background(T.bg)
        .foregroundStyle(T.ink)
        .tint(T.accent)
        // Windows opened by Claude through the show_window tool.
        .onReceive(NotificationCenter.default.publisher(for: .cueVideoShowWindow)) { n in
            // The names from when each of these was its own window.
            switch n.object as? String {
            case "setup": booth.show(.setup)
            case "switcher": booth.show(.switcher)
            case "routing": booth.show(.routing)
            case "scan": booth.show(.scan)
            case "status": booth.show(.status)
            case "engineer": booth.view = .engineer
            default: booth.view = .operate
            }
            NSApp.windows.first { $0.title == Booth.mainWindowTitle }?.makeKeyAndOrderFront(nil)
        }
    }
}

/// The one bar across the top: the page tabs, whether we're connected, small live previews
/// of what's on air and of the pinned screens, and recording and streaming.
struct TopBar: View {
    static let height: CGFloat = 68
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController

    var body: some View {
        HStack(spacing: T.s3) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26).padding(.leading, 68)
                .help("Churchfront Video")
            PageTabs()
            LinkPill()
            let down = ptz.cameras.filter { !$0.host.isEmpty && !ptz.online.contains($0.id) }
            let waiting = ptz.cameras.filter { ptz.online.contains($0.id) && !ptz.hasControl($0) }
            let problem = (down.isEmpty ? [] : ["\(down.map(\.name).joined(separator: ", ")) not answering"])
                + (waiting.isEmpty ? [] : ["\(waiting.map(\.name).joined(separator: ", ")) waiting for control"])
            if !problem.isEmpty {
                Text(problem.joined(separator: " · ")).font(.sans(12, .semibold)).foregroundStyle(T.warning).lineLimit(1)
                    .help("Canon cameras take commands from one controller at a time. A logged-in session, like the camera's own web page, outranks Churchfront Video.")
            }
            if atem.state.ftbBlack[booth.me] ?? false {
                Text("Faded to black").font(.sans(12, .bold)).foregroundStyle(T.warning).lineLimit(1)
            }
            Spacer(minLength: T.s2)
            TopMonitors()
            if atem.state.hasRecording {
                StatusButton(title: atem.state.recording ? "Recording" : "Record", on: atem.state.recording, color: T.program) {
                    atem.setRecording(!atem.state.recording)
                }
            }
            if atem.state.hasStreaming { StatusButton(title: atem.state.streaming ? "Streaming" : (atem.state.streamConnecting ? "Connecting" : "Stream"),
                         on: atem.state.streaming || atem.state.streamConnecting, color: atem.state.streaming ? T.program : T.warning) {
                atem.setStreaming(!(atem.state.streaming || atem.state.streamConnecting))
            } }
        }
        .padding(.horizontal, T.s3)
        .frame(height: TopBar.height)
        .background(T.toolbar)
    }
}

/// Operate, then the other pages. Space, Return and the number keys only cut and fade on Operate.
struct PageTabs: View {
    @EnvironmentObject var booth: Booth

    var body: some View {
        // Tabs in the CueScreens manner: caps labels, the one you're on in accent with a line under it.
        HStack(spacing: T.s4) {
            tab("Operate", "slider.horizontal.3", "The booth screen: pick, frame, take (⌘1)", on: booth.view == .operate) { booth.view = .operate }
            ForEach(EngineerSection.allCases) { s in
                tab(s.title, s.icon, s.note + ". Space, Return and the number keys do nothing here, so they can't cut or fade.",
                    on: booth.view == .engineer && booth.section == s) { booth.show(s) }
            }
        }
        .fixedSize()
    }

    private func tab(_ title: String, _ icon: String, _ help: String, on: Bool, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                LabelText(title, size: 11)
            }
            .foregroundStyle(on ? T.accent : T.inkMuted)
            .frame(height: TopBar.height)
            .overlay(alignment: .bottom) { Rectangle().fill(on ? T.accent : .clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Small live pictures in the top bar: Live and Next (on every page but Operate, which has
/// them large), then the pinned screens, each showing what it's showing now.
struct TopMonitors: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let s = atem.state
        HStack(alignment: .top, spacing: T.s2) {
            if booth.view != .operate {
                monitor(s.program[booth.me], caption: store.label(s.program[booth.me], s), tag: ("Live", T.program, .white),
                        help: "Live now. Click to go to Operate.") { booth.view = .operate }
                monitor(s.preview[booth.me], caption: store.label(s.preview[booth.me], s), tag: ("Next", T.preview, T.onAction),
                        help: "On Next. Click to go to Operate.") { booth.view = .operate }
                if !store.pinnedScreens.isEmpty { Rectangle().fill(T.line).frame(width: 1, height: 52) }
            }
            ForEach(store.pinnedScreens) { sc in
                let now = Set(sc.aux.map { s.aux[$0 - 1] })
                let src: Int? = now.count == 1 ? (now.first ?? nil) : nil
                monitor(src, caption: sc.name, tag: nil,
                        help: "\(sc.name) is showing \(now.count > 1 ? "different pictures on its outputs" : store.routeLabel(src, s)). Click to open Routing.") { booth.show(.routing) }
            }
        }
    }

    private func monitor(_ input: Int?, caption: String, tag: (String, Color, Color)?, help: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            VStack(spacing: 2) {
                ZStack(alignment: .topLeading) {
                    SourcePicture(input: input, named: false)
                    if !sourceHasPicture(input, atem.state, ptz, store) {
                        Text(input == nil ? "Mixed" : store.routeLabel(input, atem.state)).font(.sans(9, .semibold)).foregroundStyle(T.inkMuted)
                            .lineLimit(tag == nil ? 2 : 1).multilineTextAlignment(.center).minimumScaleFactor(0.7).padding(3)
                            .padding(.top, tag == nil ? 0 : 14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let tag { Tag(text: tag.0, color: tag.1, ink: tag.2).padding(2) }
                }
                .frame(width: 71, height: 40)
                .clipShape(Rectangle())
                .overlay(Rectangle().stroke(tag?.1 ?? T.line, lineWidth: tag?.0 == "Live" ? 2 : 1))
                Text(caption).font(.sans(10, .medium)).foregroundStyle(T.inkMuted).lineLimit(1).frame(width: 71)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct StatusButton: View {
    let title: String
    let on: Bool
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(on ? color : T.lineStrong).frame(width: 8, height: 8)
                LabelText(title, size: 11)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(on ? color.opacity(0.18) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(on ? color.opacity(0.6) : T.lineStrong))
        }
        .buttonStyle(.plain)
    }
}

struct LinkPill: View {
    @EnvironmentObject var atem: ATEMClient
    var body: some View {
        let (text, color): (String, Color) = {
            switch atem.link {
            case .online: return ("Online", T.success)
            case .connecting: return ("Connecting", T.warning)
            case .offline: return ("Offline", T.danger)
            case .idle: return ("Not set up", T.inkSubtle)
            }
        }()
        Badge(text: text, tone: color == T.success ? .success : (color == T.warning ? .warning : (color == T.danger ? .danger : .neutral)), dot: true)
    }
}

struct LinkBanner: View {
    @EnvironmentObject var atem: ATEMClient
    var body: some View {
        if case .offline(let why) = atem.link {
            Text("\(why). Reconnecting on its own; buttons do nothing until it's back.")
                .font(.sans(13, .semibold)).foregroundStyle(T.onAction)
                .padding(.horizontal, T.s4).padding(.vertical, T.s2)
                .background(Capsule().fill(T.warning)).padding(.top, T.s3)
        }
    }
}

/// Tells the booth when the setup file has a mistake in it, on the main screen and not only in Setup.
struct ConfigBanner: View {
    @EnvironmentObject var store: ConfigStore
    var body: some View {
        if store.fileError != nil {
            Text("The setup file has a mistake in it, so Churchfront Video is using the last good setup. Details are in Setup (⌘,).")
                .font(.sans(13, .semibold)).foregroundStyle(T.onAction)
                .padding(.horizontal, T.s4).padding(.vertical, T.s2)
                .background(Capsule().fill(T.warning)).padding(.top, T.s3)
        }
    }
}

struct ConnectView: View {
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var atem: ATEMClient
    @State private var host = Booth.shared.store.config.atemHost
    @State private var kind = Booth.shared.store.config.switcher

    var body: some View {
        VStack(spacing: T.s4) {
            Spacer()
            Text("Connect to your switcher").font(.sans(26, .bold))
            Segments(items: SwitcherKind.allCases.map { ($0.title, $0) }, selection: $kind)
            Text(kind == .atem
                 ? "Churchfront Video talks to the switcher directly over your network. No Blackmagic software needed.\nFind the switcher's IP address in ATEM Setup under Network."
                 : "Churchfront Video talks to the switcher directly over your network (PVS0403U, HVS0403U, HVS0402U).\nFind its IP address in the switcher's menu under Network, and close AVMATRIX's control software on this Mac.")
                .font(.sans(14)).foregroundStyle(T.inkMuted).multilineTextAlignment(.center)
            HStack {
                TextField("Such as 192.168.1.240", text: $host)
                    .textFieldStyle(.plain).font(.sans(16))
                    .padding(.horizontal, T.s3).frame(width: 260, height: 40)
                    .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken))
                    .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
                    .onSubmit(go)
                Button(action: go) {
                    Text("Connect").font(.sans(15, .bold)).foregroundStyle(T.onAction)
                        .padding(.horizontal, T.s5).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.accent))
                }.buttonStyle(.plain)
            }
            if let e = store.fileError {
                Text("The setup file couldn't be read, so nothing from it is loaded: \(e)\nFix it in Setup (⌘,), or connect here to start again. The file is kept under another name before anything is saved over it.")
                    .foregroundStyle(T.warning).multilineTextAlignment(.center).frame(maxWidth: 560)
            }
            switch atem.link {
            case .connecting: Text("Connecting to \(atem.host)…").foregroundStyle(T.warning)
            case .offline(let why): Text(why).foregroundStyle(T.danger)
            default: EmptyView()
            }
            Spacer()
        }
        .font(.sans(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func go() {
        Booth.shared.store.update { $0.switcher = kind; $0.atemHost = host.trimmingCharacters(in: .whitespaces) }
    }
}

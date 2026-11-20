import Foundation
import AppKit

/// Adds Churchfront Video to the Claude desktop app, so a church's Claude can set it up and
/// run it (through cuevideo-mcp, inside this app). One button in Setup > AI assistant.
///
/// Claude Desktop reads its local connectors from
/// ~/Library/Application Support/Claude/claude_desktop_config.json, under "mcpServers".
/// We add or update one entry, "churchfront-video", and leave everything else in the file
/// as it was. The first time we change an existing file, a copy is kept beside it.
enum ClaudeConnect {
    static let serverName = "churchfront-video"

    enum State: Equatable {
        case noClaude          // Claude Desktop isn't installed
        case notConnected
        case connected
        case stalePath         // connected, but to a copy of the app somewhere else
        case runFromDownloads  // this copy is running from the disk image or Downloads
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// The MCP server inside this copy of the app.
    static var serverPath: String { Bundle.main.bundlePath + "/Contents/MacOS/cuevideo-mcp" }

    static var claudeInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Claude.app")
    }

    /// Running from the disk image, or from a quarantined copy macOS moved aside: the path
    /// would stop working once the disk image is ejected, so ask for Applications first.
    static var runningFromTemporaryPlace: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Volumes/") || p.contains("/AppTranslocation/")
    }

    static func state() -> State {
        if runningFromTemporaryPlace { return .runFromDownloads }
        guard claudeInstalled else { return .noClaude }
        guard let entry = readConfig()["mcpServers"].flatMap({ $0 as? [String: Any] })?[serverName] as? [String: Any] else { return .notConnected }
        return (entry["command"] as? String) == serverPath ? .connected : .stalePath
    }

    private static func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// Adds (or points at this copy) the churchfront-video entry. Returns an error message,
    /// or nil when it worked.
    @discardableResult
    static func connect() -> String? {
        if runningFromTemporaryPlace { return "Move Churchfront Video to your Applications folder and open it from there first." }
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: configURL.path)
        var config: [String: Any] = [:]
        if exists {
            guard let data = try? Data(contentsOf: configURL) else { return "Couldn't read Claude's settings file." }
            if !data.isEmpty {
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return "Claude's settings file has a problem, so it was left alone: \(configURL.path)"
                }
                config = obj
            }
            let backup = configURL.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.before-churchfront-video.json")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: configURL, to: backup) }
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": serverPath, "args": [String]()]
        config["mcpServers"] = servers
        do {
            try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: configURL, options: .atomic)
        } catch {
            return "Couldn't save Claude's settings: \(error.localizedDescription)"
        }
        return state() == .connected ? nil : "Saved, but Claude's settings didn't read back as expected."
    }

    /// Takes the churchfront-video entry out again, leaving the rest of the file alone.
    @discardableResult
    static func disconnect() -> String? {
        var config = readConfig()
        guard var servers = config["mcpServers"] as? [String: Any] else { return nil }
        servers[serverName] = nil
        config["mcpServers"] = servers
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: configURL, options: .atomic)
            return nil
        } catch { return "Couldn't save Claude's settings: \(error.localizedDescription)" }
    }

    /// What to say to Claude after connecting.
    static let firstPrompt = "Help me set up Churchfront Video for our church. Find our video switcher and PTZ cameras on the network, check with me which camera is which, and set them up."
}

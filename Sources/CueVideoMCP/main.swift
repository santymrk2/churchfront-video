import Foundation

// CueVideo's MCP server, for Claude. It speaks MCP (JSON-RPC over stdin and stdout) and
// passes every tool call to the running CueVideo app through its local control interface
// (127.0.0.1:9911, with the key in ~/Library/Application Support/CueVideo/control-token).
// The tools themselves are defined in the app (ControlTools.swift), so this stays tiny.
// If CueVideo isn't open, calling a tool opens it in the background first. Listing the tools doesn't.

let port = 9911
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("CueVideo", isDirectory: true)

/// The tool list CueVideo gave last time, for when it's closed.
let toolsCache = support.appendingPathComponent("mcp-tools.json")

func token() -> String {
    (try? String(contentsOf: support.appendingPathComponent("control-token"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// One request to the app; nil body for GET. Returns the JSON reply, or nil if the app didn't answer.
func app(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: Double = 30) -> [String: Any]? {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: timeout)
    r.httpMethod = method
    r.setValue(token(), forHTTPHeaderField: "X-CueVideo-Token")
    if let body {
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    var out: [String: Any]?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: r) { data, _, _ in
        out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        done.signal()
    }.resume()
    done.wait()
    return out
}

/// The app this program ships in: …/CueVideo.app/Contents/MacOS/cuevideo-mcp.
func appBundle() -> URL? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return bundle.pathExtension == "app" ? bundle : nil
}

/// Makes sure CueVideo is running and answering; opens it (in the background) if not.
func ensureApp() -> Bool {
    if app("GET", "/tools", timeout: 2) != nil { return true }
    guard let bundle = appBundle() else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", bundle.path]
    try? p.run()
    p.waitUntilExit()
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.5)
        if app("GET", "/tools", timeout: 2) != nil { return true }
    }
    return false
}

let notRunning = "Churchfront Video isn't running or isn't answering on 127.0.0.1:\(port). Open Churchfront Video on this Mac and try again."

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func result(_ id: Any, _ r: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": r]) }
func failure(_ id: Any, _ code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
          let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
    let method = msg["method"] as? String ?? ""
    guard let id = msg["id"] else { continue }  // notifications (such as notifications/initialized) need no answer
    let params = msg["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        let asked = params["protocolVersion"] as? String ?? supported[0]
        result(id, [
            "protocolVersion": supported.contains(asked) ? asked : supported[0],
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "cuevideo", "version": "0.1.1"],
            "instructions": "Controls Churchfront Video, the church booth app for an ATEM or AVMATRIX switcher and PTZ cameras. Setting it up for the first time (get_config shows no atemHost or no cameras): call find_devices to locate the ATEM and cameras on the network (an AVMATRIX isn't found that way: ask for its IP address and set switcher \"avmatrix\"), confirm with the person which camera is which and which switcher input each feeds, save them with update_config (atemHost, cameras with name, host, proto, atemInput), then list_ndi_sources for previews and add sources and key buttons. Explain each step in plain words; the person may be a volunteer. Running it: call get_status first to see what's Live and Next, the sources, cameras, shots and key buttons. Cuts, fades and Live changes go out to the congregation and the stream immediately, so confirm with the person before changing what's live during a service. Camera tools act on the camera on Next unless one is named, and refuse a camera that's on Live unless allow_live is true.",
        ])
    case "ping":
        result(id, [:])
    case "tools/list":
        // Listing the tools never opens CueVideo: a Claude session starting in this folder
        // must not bring up an app that connects to the switcher and takes control of the
        // cameras. While CueVideo is closed, the list it gave last time is used; calling a
        // tool is what opens it.
        if let r = app("GET", "/tools", timeout: 2), let tools = r["tools"] {
            if let data = try? JSONSerialization.data(withJSONObject: tools) { try? data.write(to: toolsCache, options: .atomic) }
            result(id, ["tools": tools])
        } else if let data = try? Data(contentsOf: toolsCache), let tools = try? JSONSerialization.jsonObject(with: data) {
            result(id, ["tools": tools])
        } else {
            result(id, ["tools": [["name": "get_status", "description": "Status of Churchfront Video. (Churchfront Video isn't running right now.)",
                                   "inputSchema": ["type": "object", "properties": [:] as [String: Any]]]]])
        }
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        // A stage scan moves each camera to a wide shot and back, which can take a while.
        guard ensureApp(), let r = app("POST", "/call", ["name": name, "arguments": args], timeout: 120) else {
            result(id, ["content": [["type": "text", "text": notRunning]], "isError": true]); continue
        }
        // Pictures (camera_snapshots) go back as MCP image content, each after a label.
        var rest = r
        let images = rest.removeValue(forKey: "images") as? [[String: Any]] ?? []
        let text = (try? JSONSerialization.data(withJSONObject: rest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var content: [[String: Any]] = [["type": "text", "text": text]]
        for img in images {
            guard let data = img["data"] as? String else { continue }
            content.append(["type": "text", "text": img["label"] as? String ?? "Picture"])
            content.append(["type": "image", "data": data, "mimeType": img["mimeType"] as? String ?? "image/jpeg"])
        }
        result(id, ["content": content, "isError": r["error"] != nil])
    default:
        failure(id, -32601, "Unknown method \(method)")
    }
}

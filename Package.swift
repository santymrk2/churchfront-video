// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CueVideo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CueVideo", targets: ["CueVideo"]),
        // The MCP server Claude uses to control CueVideo (ships inside CueVideo.app).
        .executable(name: "cuevideo-mcp", targets: ["CueVideoMCP"]),
        // The ATEM and PTZ engine, shared with CueScreens and CueStack.
        .library(name: "CueATEM", targets: ["CueATEM"]),
    ],
    dependencies: [
        // Churchfront Kit (formerly CueKit), shared with the other suite apps: the Signal design tokens and Figtree.
        .package(url: "https://github.com/Churchfront/churchfront-kit.git", from: "0.2.1"),
    ],
    targets: [
        .target(name: "CueATEM", path: "Sources/CueATEM"),
        // NDI in by loading the runtime at run time (no SDK needed to build).
        .target(name: "NDIBridge", path: "Sources/NDIBridge"),
        .executableTarget(name: "CueVideoMCP", path: "Sources/CueVideoMCP"),
        // For trying auto tracking with no PTZ camera: this Mac's webcam as NDI, cropped to
        // where a pretend camera from Tools/fake_ptz.py points. swift run FakeCamera
        .executableTarget(name: "FakeCamera", dependencies: ["NDIBridge"], path: "Tools/FakeCamera"),
        .executableTarget(
            name: "CueVideo",
            dependencies: ["CueATEM", "NDIBridge", .product(name: "CueDesign", package: "churchfront-kit")],
            path: "Sources/CueVideo"
        ),
        // Runs the camera code against pretend cameras on this Mac: swift test
        .testTarget(name: "CueATEMTests", dependencies: ["CueATEM"], path: "Tests/CueATEMTests"),
        .testTarget(name: "CueVideoTests", dependencies: ["CueVideo", "CueATEM"], path: "Tests/CueVideoTests"),
    ]
)

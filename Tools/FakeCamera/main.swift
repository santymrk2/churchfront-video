// A pretend PTZ camera with a real picture: this Mac's webcam, sent as NDI, cropped to
// where a pretend camera from Tools/fake_ptz.py points. With both running, Churchfront
// Video can move the camera and watch its picture, so auto tracking can be tried on a
// person in front of the webcam, with no PTZ camera.
//
//     python3 Tools/fake_ptz.py
//     swift run FakeCamera                      (sends "Fake PTZ 1", following camera 1)
//
// The webcam's whole picture stands for the stage as the pretend camera sees it zoomed all
// the way out (58 degrees across, as the app reckons for these cameras). Panning moves the
// crop across it, zooming makes the crop smaller, so what the app sees matches the angles
// it asks for, and tracking works on it as on a real camera. Past the webcam's edges the
// picture is black.
//
// Options:
//   --camera N        follow pretend camera N (default 1); the NDI name is "Fake PTZ N"
//   --name NAME       another NDI name
//   --state URL       where fake_ptz.py reports its cameras (default http://localhost:8090/state)
//   --still           send the whole webcam picture, following no camera
//   --device TEXT     use the camera whose name contains TEXT (see --list)
//   --list            list the cameras and quit
//
// The NDI runtime comes from NDI Tools, as for the app. The first run asks for camera access
// for the Terminal (System Settings > Privacy & Security > Camera).

import AVFoundation
import CoreImage
import Foundation
import NDIBridge

// MARK: Options

struct Options {
    var camera = 1
    var name: String?
    var state = URL(string: "http://localhost:8090/state")!
    var still = false
    var device: String?
    var list = false

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 1
        func value() -> String {
            i += 1
            guard i < args.count else { fail("\(args[i - 1]) needs a value.") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--camera": o.camera = Int(value()) ?? 1
            case "--name": o.name = value()
            case "--state": o.state = URL(string: value()) ?? o.state
            case "--still": o.still = true
            case "--device": o.device = value()
            case "--list": o.list = true
            case "-h", "--help":
                print("swift run FakeCamera [--camera N] [--name NAME] [--state URL] [--still] [--device TEXT] [--list]")
                exit(0)
            default: fail("Unknown option \(args[i]). Try --help.")
            }
            i += 1
        }
        return o
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: Where the pretend camera points

/// Pan, tilt and angle of view of one pretend camera, read from fake_ptz.py about 20 times
/// a second.
final class PTZFollower {
    struct View { var pan = 0.0, tilt = 0.0, fov = FakeCamera.wideFOV }

    private let url: URL
    private let camera: Int
    private let lock = NSLock()
    private var view = View()
    private var asking = false
    private var timer: DispatchSourceTimer?
    private(set) var reached = false

    init(url: URL, camera: Int) {
        self.url = url
        self.camera = camera
    }

    var current: View { lock.lock(); defer { lock.unlock() }; return view }
    var connected: Bool { lock.lock(); defer { lock.unlock() }; return reached }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.ask() }
        t.resume()
        timer = t
    }

    private func ask() {
        lock.lock()
        guard !asking else { lock.unlock(); return }
        asking = true
        lock.unlock()
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            let cams = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            let cam = cams?.first { ($0["n"] as? Int) == self.camera }
            self.lock.lock()
            self.asking = false
            self.reached = cam != nil
            if let cam, let pan = cam["pan"] as? Double, let tilt = cam["tilt"] as? Double, let fov = cam["fov"] as? Double {
                self.view = View(pan: pan, tilt: tilt, fov: fov)
            }
            self.lock.unlock()
        }.resume()
    }
}

// MARK: Webcam to NDI

final class FakeCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// The pretend camera's angle of view zoomed all the way out: what the webcam's whole
    /// width stands for. The same as the app's VISCAUnits.ptzOptics.wideFOV.
    static let wideFOV = 58.0
    static let size = (width: 1280, height: 720)

    private let sender: UnsafeMutableRawPointer
    private let follower: PTZFollower?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let output: CVPixelBuffer
    private let frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    private let black: CIImage
    private let statsLock = NSLock()
    private var sent = 0

    init(name: String, follower: PTZFollower?) {
        guard let s = ndi_send_open(name) else {
            fail("Couldn't start NDI. Install NDI Tools (ndi.video/tools), as Churchfront Video's NDI previews need.")
        }
        sender = s
        self.follower = follower
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        _ = CVPixelBufferCreate(nil, Self.size.width, Self.size.height, kCVPixelFormatType_32BGRA, attrs, &pb)
        guard let pb else { fail("Couldn't make a picture buffer.") }
        output = pb
        black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height))
    }

    /// Frames sent since the last call.
    func takeCount() -> Int {
        statsLock.lock(); defer { statsLock.unlock() }
        let n = sent
        sent = 0
        return n
    }

    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let webcam = CIImage(cvPixelBuffer: pixels)
        let w = webcam.extent.width, h = webcam.extent.height
        let view = follower?.current ?? PTZFollower.View()

        // The part of the webcam picture the pretend camera sees. Core Image counts y up from
        // the bottom, as tilt does.
        let perDegree = w / Self.wideFOV
        let cropW = max(16, view.fov * perDegree)
        let cropH = cropW * Double(Self.size.height) / Double(Self.size.width)
        let crop = CGRect(x: w / 2 + view.pan * perDegree - cropW / 2,
                          y: h / 2 + view.tilt * perDegree - cropH / 2,
                          width: cropW, height: cropH)
        let scale = Double(Self.size.width) / cropW
        let shown = webcam
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
            .composited(over: black)
            .cropped(to: frame)

        context.render(shown, to: output, bounds: frame, colorSpace: colorSpace)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(output) {
            ndi_send_frame(sender, base.assumingMemoryBound(to: UInt8.self), Int32(Self.size.width), Int32(Self.size.height),
                           Int32(CVPixelBufferGetBytesPerRow(output)), 30000, 1001)
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        statsLock.lock(); sent += 1; statsLock.unlock()
    }
}

// MARK: Main

let options = Options.parse(CommandLine.arguments)
let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                               mediaType: .video, position: .unspecified).devices
if options.list {
    print(devices.isEmpty ? "No cameras found." : devices.map { "  \($0.localizedName)" }.joined(separator: "\n"))
    exit(0)
}
guard let device = options.device.map({ d in devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(d) }) })
        ?? AVCaptureDevice.default(for: .video) ?? devices.first else {
    fail(options.device.map { "No camera called \($0). Try --list." } ?? "No camera found.")
}

if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
    let asked = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in asked.signal() }
    asked.wait()
}
guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    fail("No camera access. Allow it for the Terminal in System Settings > Privacy & Security > Camera, then run this again.")
}

let ndiName = options.name ?? "Fake PTZ \(options.camera)"
let follower = options.still ? nil : PTZFollower(url: options.state, camera: options.camera)
let fake = FakeCamera(name: ndiName, follower: follower)

let session = AVCaptureSession()
for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high] where session.canSetSessionPreset(preset) {
    session.sessionPreset = preset
    break
}
guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
    fail("Couldn't open \(device.localizedName).")
}
session.addInput(input)
let videoOut = AVCaptureVideoDataOutput()
videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
videoOut.alwaysDiscardsLateVideoFrames = true
videoOut.setSampleBufferDelegate(fake, queue: DispatchQueue(label: "fakecamera.frames"))
guard session.canAddOutput(videoOut) else { fail("Couldn't read pictures from \(device.localizedName).") }
session.addOutput(videoOut)
session.startRunning()
follower?.start()

print("Sending \(device.localizedName) as NDI \"\(ndiName)\" (1280x720).")
print(options.still ? "Whole picture, following no camera." : "Following pretend camera \(options.camera) from \(options.state.absoluteString).")
print("Ctrl+C to stop.")

// Once every 2 seconds: frames sent, and where the pretend camera points.
let status = DispatchSource.makeTimerSource(queue: .main)
status.schedule(deadline: .now() + 2, repeating: 2)
status.setEventHandler {
    let fps = Double(fake.takeCount()) / 2
    var line = String(format: "%.0f frames a second", fps)
    if let follower {
        let v = follower.current
        line += follower.connected
            ? String(format: " · pan %.1f°, tilt %.1f°, zoom %.1fx", v.pan, v.tilt, FakeCamera.wideFOV / v.fov)
            : " · fake_ptz.py not answering at \(options.state.absoluteString): sending the whole picture"
    }
    print(line)
}
status.resume()
dispatchMain()

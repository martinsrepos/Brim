import AppKit
@preconcurrency import AVFoundation
import SwiftUI
import Observation

/// The camera behind the panel's Mirror. One session, started when the mirror
/// shows and stopped when it closes, so the camera is never on in the
/// background. Asks for Camera access the first time.
///
/// Real cameras come first (built in, an external webcam, an iPhone used as
/// Continuity Camera); virtual ones such as OBS Virtual Camera come last.
/// The switch button picks another one, and Brim remembers your choice.
@MainActor
@Observable
final class MirrorCamera {
    enum Access { case unknown, allowed, denied, noCamera }

    struct Camera: Identifiable, Equatable {
        let id: String
        let name: String
    }

    static let shared = MirrorCamera()

    private(set) var access: Access = .unknown
    private(set) var cameras: [Camera] = []
    private(set) var currentID: String?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.brim.mirror")
    @ObservationIgnored private var input: AVCaptureDeviceInput?

    var currentName: String? { cameras.first { $0.id == currentID }?.name }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .allowed
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let camera = MirrorCamera.shared
                        camera.access = granted ? .allowed : .denied
                        if granted { camera.run() }
                    }
                }
            }
        default:
            access = .denied
        }
    }

    func stop() {
        let session = self.session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    /// The next camera in the list.
    func switchCamera() {
        let devices = Self.devices()
        guard devices.count > 1 else { return }
        let index = devices.firstIndex { $0.uniqueID == currentID } ?? -1
        let next = devices[(index + 1) % devices.count]
        UserDefaults.standard.set(next.uniqueID, forKey: "mirrorCamera")
        use(next)
    }

    private func run() {
        let devices = Self.devices()
        cameras = devices.map { Camera(id: $0.uniqueID, name: $0.localizedName) }
        let preferred = UserDefaults.standard.string(forKey: "mirrorCamera")
        guard let device = devices.first(where: { $0.uniqueID == preferred }) ?? devices.first else {
            access = .noCamera
            return
        }
        use(device)
    }

    /// Swaps the session's camera and starts it, all on the session's own
    /// queue so the session is never changed and started at the same time.
    private func use(_ device: AVCaptureDevice) {
        guard let newInput = try? AVCaptureDeviceInput(device: device) else {
            appLog.error("Mirror: couldn't open \(device.localizedName, privacy: .public)")
            return
        }
        let old = input
        input = newInput
        currentID = device.uniqueID
        let session = self.session
        queue.async {
            session.beginConfiguration()
            if let old { session.removeInput(old) }
            if session.canAddInput(newInput) { session.addInput(newInput) }
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Video cameras, real ones first.
    private static func devices() -> [AVCaptureDevice] {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified).devices
        return found.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ device: AVCaptureDevice) -> Int {
        let name = device.localizedName.lowercased()
        let virtual = ["virtual", "obs", "snap camera", "mmhmm", "camo"].contains { name.contains($0) }
        if virtual { return 3 }
        if device.deviceType == .builtInWideAngleCamera { return 0 }
        if device.deviceType == .continuityCamera { return 1 }
        return 2
    }
}

/// The live camera image, mirrored like a real mirror and filling its frame.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    static func dismantleNSView(_ view: PreviewView, coordinator: ()) {
        view.preview.session = nil
    }

    final class PreviewView: NSView {
        let preview = AVCaptureVideoPreviewLayer()
        private var startObserver: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
            // The connection only exists once the session is running; check
            // the mirroring again then.
            startObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.didStartRunningNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        deinit {
            if let startObserver { NotificationCenter.default.removeObserver(startObserver) }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Mirrored like a real mirror, by flipping the layer itself. This
            // works for every camera, including ones (external webcams, OBS)
            // whose connection doesn't support mirroring.
            preview.bounds = bounds
            preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
            preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            CATransaction.commit()
            // Keep the connection itself unmirrored, so the image isn't
            // flipped twice when macOS would mirror it on its own.
            if let connection = preview.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                if connection.isVideoMirrored { connection.isVideoMirrored = false }
            }
        }
    }
}

import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import SwiftUI

/// Turntable clips of AirPods and Beats for the device banners, the way
/// iPhone shows them: a short looping video per model, played by Core
/// Animation (AVPlayerLooper), so it costs next to nothing.
///
/// Brim ships AirPods Pro clips, rendered from a free 3D model (see
/// README's credits). It plays the clips it finds in either of two folders,
/// your own first, named after the model
/// (`airpodsPro.mov`, `airpodsMax.mov`, `airpodsGen4.mov`...), with `Open`
/// on the end for the open case with the earbuds in it and `Case` for the
/// closed case on its own (`airpodsProOpen.mov`, `airpodsProCase.mov`):
/// - Brim's own Resources/DeviceAnimations: sprite sheets (.webp, see
///   SpriteSheets);
/// - ~/Library/Application Support/Brim/DeviceAnimations, for clips you add
///   for yourself. Transparent ones play as they are; ones on black get the
///   black keyed out.
@MainActor
enum DeviceAnimations {
    struct Clip {
        let url: URL
        /// A sprite sheet (Brim's own: every frame in one image, sharp and
        /// truly transparent) rather than a video.
        var isSheet: Bool { url.pathExtension.lowercased() != "mov" }
        /// One of yours: it may be drawn on black, in which case the black is
        /// made transparent (checked when it plays).
        let mayBeOnBlack: Bool
    }

    static let userFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Brim/DeviceAnimations")
    private static let bundledFolder = Bundle.main.resourceURL?.appendingPathComponent("DeviceAnimations")

    private static var lastLog = ""

    /// Once per change, not on every redraw of the banner.
    private static func log(_ text: String) {
        guard text != lastLog else { return }
        lastLog = text
        Diag.event(text)
    }

    /// One turntable per family: every AirPods Pro shows the Pro, every
    /// AirPods Max the Max, and any other AirPods the AirPods 4. Checked in
    /// this order, so "AirPods Pro" isn't taken for plain "AirPods".
    private static let models: [(key: String, files: [String])] = [
        ("airpods pro", ["airpodsPro"]),
        ("airpods max", ["airpodsMax"]),
        ("airpods", ["airpodsGen4"]),
    ]

    /// The clip for a device name ("Martin's AirPods Pro"); its case's clip
    /// when the case was opened nearby, if there is one.
    /// Gets the clips for these AirPods ready in the background, so the
    /// banner starts turning the moment it drops.
    static func preload(forDevice name: String) {
        let urls = [Variant.buds, .openCase, .closedCase].compactMap { variant -> URL? in
            guard let clip = clip(forDevice: name, variant: variant), clip.isSheet else { return nil }
            return clip.url
        }
        SpriteSheets.preload(Array(Set(urls)))
    }

    /// What the banner is about: the earbuds (connected), the open case
    /// with them inside (opened next to the Mac), or the case on its own.
    enum Variant: String {
        case buds = "", openCase = "Open", closedCase = "Case"
    }

    static func clip(forDevice name: String, variant: Variant) -> Clip? {
        let n = name.lowercased()
        guard let files = models.first(where: { n.contains($0.key) })?.files else {
            log("device clip: no model for \"\(name)\"")
            return nil
        }
        // Falls back from the open case to the closed one, then the earbuds.
        let order: [Variant] = switch variant {
        case .buds: [.buds]
        case .openCase: [.openCase, .closedCase, .buds]
        case .closedCase: [.closedCase, .openCase, .buds]
        }
        // A video of yours first, then Brim's own sheet (or video).
        let wanted = files.flatMap { file in order.flatMap { variant in
            ["mov", "webp"].map { (file + variant.rawValue).lowercased() + "." + $0 }
        } }
        let folders = [(userFolder, true)] + (bundledFolder.map { [($0, false)] } ?? [])
        for name in wanted {
            for (folder, onBlack) in folders {
                // Case-insensitive, so "beatssolo.mov" counts as "beatsSolo".
                let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                if let match = files.first(where: { $0.lowercased() == name }) {
                    let url = folder.appendingPathComponent(match)
                    log("device clip: \(match)\(onBlack ? " (yours)" : "")")
                    return Clip(url: url, mayBeOnBlack: onBlack)
                }
            }
        }
        log("device clip: none of \(wanted.joined(separator: ", ")) found")
        return nil
    }
}

/// Brim's own clips: a sprite sheet, every frame of the turn in one WebP
/// image (12 across, 144 frames of 128 pixels, 24 a second), stepped
/// through by Core Animation. Sharper than a video at this size, with real
/// transparency.
struct DeviceSheetView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> SpriteSheetView { SpriteSheetView(url: url) }
    func updateNSView(_ view: SpriteSheetView, context: Context) {}
}

final class SpriteSheetView: NSView {
    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
        if let frames = SpriteSheets.cached(url) {
            start(frames)
        } else {
            // Not ready yet (it's normally loaded ahead): fade in once it is.
            Task { @MainActor [weak self] in
                guard let frames = await SpriteSheets.load(url) else { return }
                self?.start(frames, fadeIn: true)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func start(_ frames: [CGImage], fadeIn: Bool = false) {
        guard let layer, let first = frames.first else { return }
        layer.contents = first
        let turn = CAKeyframeAnimation(keyPath: "contents")
        turn.values = frames
        turn.calculationMode = .discrete
        turn.duration = Double(frames.count) / SpriteSheets.fps
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        layer.add(turn, forKey: "turn")
        if fadeIn {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.2
            layer.add(fade, forKey: "fade")
        }
    }
}

/// Decoded sheets, cut into frames of their own (so each frame is a small
/// image the graphics side can show directly). Decoded off the main thread,
/// ahead of time for your AirPods, and only the last few are kept.
@MainActor
enum SpriteSheets {
    static let columns = 12
    static let frameCount = 144
    static let fps = 24.0
    private static var cache: [URL: [CGImage]] = [:]
    private static var order: [URL] = []
    private static var loading: [URL: Task<[CGImage]?, Never>] = [:]

    static func cached(_ url: URL) -> [CGImage]? { cache[url] }

    static func load(_ url: URL) async -> [CGImage]? {
        if let frames = cache[url] { return frames }
        if let task = loading[url] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { decode(url) }
        loading[url] = task
        let frames = await task.value
        loading[url] = nil
        if let frames {
            cache[url] = frames
            order.removeAll { $0 == url }
            order.append(url)
            // Three is one model's earbuds, open case and closed case.
            while order.count > 3 { cache[order.removeFirst()] = nil }
        } else {
            Diag.event("device clip: couldn't read \(url.lastPathComponent)")
        }
        return frames
    }

    /// Loads in the background; nothing waits for it.
    static func preload(_ urls: [URL]) {
        for url in urls where cache[url] == nil { Task { _ = await load(url) } }
    }

    private nonisolated static func decode(_ url: URL) -> [CGImage]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let side = sheet.width / columns
        guard side > 0, sheet.height >= side * ((frameCount + columns - 1) / columns),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            // Left to right, top to bottom (CGImage counts from the top).
            guard let cell = sheet.cropping(to: CGRect(x: (i % columns) * side, y: (i / columns) * side, width: side, height: side)),
                  let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(cell, in: CGRect(x: 0, y: 0, width: side, height: side))
            guard let frame = context.makeImage() else { return nil }
            frames.append(frame)
        }
        return frames
    }
}

/// A clip that loops silently, scaled to fit.
struct DeviceAnimationView: NSViewRepresentable {
    let clip: DeviceAnimations.Clip

    func makeNSView(context: Context) -> LoopingVideoView { LoopingVideoView(clip: clip) }
    func updateNSView(_ view: LoopingVideoView, context: Context) {}

    static func dismantleNSView(_ view: LoopingVideoView, coordinator: ()) { view.stop() }
}

final class LoopingVideoView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var stopped = false
    private let playerLayer: AVPlayerLayer

    init(clip: DeviceAnimations.Clip) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .clear
        // Keeps the clip's transparency.
        playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        layer?.addSublayer(playerLayer)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let asset = AVURLAsset(url: clip.url)
        if clip.mayBeOnBlack {
            Task { @MainActor [weak self] in
                let keyed = await !Self.hasAlpha(asset)
                self?.play(asset, keyingBlack: keyed)
            }
        } else {
            play(asset, keyingBlack: false)
        }
    }

    private func play(_ asset: AVURLAsset, keyingBlack: Bool) {
        guard !stopped else { return }
        let item = AVPlayerItem(asset: asset)
        if keyingBlack {
            // Luma key: brightness becomes opacity (boosted, so the device
            // itself stays solid and only the black around it goes).
            item.videoComposition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
                let keyed = request.sourceImage.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 1.8, y: 3.6, z: 0.6, w: 0),
                ])
                request.finish(with: keyed, context: nil)
            })
        }
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
        // If the clip can't play, say why in the diagnostics report.
        statusObservation = looper?.observe(\.status) { looper, _ in
            guard looper.status == .failed else { return }
            let reason = looper.error?.localizedDescription ?? "unknown error"
            Task { @MainActor in Diag.event("device clip failed: \(reason)") }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The clip has its own transparency (ProRes 4444, HEVC with alpha).
    private nonisolated static func hasAlpha(_ asset: AVURLAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let description = try? await track.load(.formatDescriptions).first else { return false }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        let flag = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool
        let depth = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_Depth) as? Int
        return flag == true || depth == 32
            || codec == kCMVideoCodecType_AppleProRes4444 || codec == kCMVideoCodecType_AppleProRes4444XQ
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func stop() {
        stopped = true
        statusObservation = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
    }
}

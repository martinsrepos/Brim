import AppKit
import SwiftUI
import os
import Observation

/// The music apps Brim can read and control.
enum PlayerApp: String, CaseIterable {
    case spotify = "Spotify"
    case music = "Music"

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    /// Only ever script an app that's already running, otherwise AppleScript launches it.
    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

struct MediaTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double  // seconds
}

@MainActor
enum AppleScript {
    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        Diag.count("media.appleScript")
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            appLog.error("AppleScript error: \(error.description, privacy: .public)")
            return nil
        }
        return result
    }
}

/// Reads now-playing info from Spotify / Music and sends play, pause, skip and seek.
/// Updates arrive instantly through the apps' own broadcast notifications;
/// AppleScript is used for details (position, artwork) and for the controls.
@MainActor
@Observable
final class MediaController {
    private(set) var player: PlayerApp?
    private(set) var track: MediaTrack?
    private(set) var isPlaying = false

    enum RepeatMode { case off, all, one }
    /// nil until the player has said (shown as off).
    private(set) var shuffleOn: Bool?
    private(set) var repeatMode: RepeatMode?
    /// Apple Music's favourite (heart) for the current song; nil elsewhere.
    private(set) var isLoved: Bool?
    /// Only Apple Music lets other apps favourite a song.
    var canLove: Bool { sourceBundleID?.lowercased() == "com.apple.music" }
    /// Which way the song title swipes when it changes: 1 = next (from the
    /// right), -1 = previous (from the left).
    private(set) var trackDirection = 1
    @ObservationIgnored private var lastPreviousPress: Date?
    /// Recently played songs, newest last: going back to the one before is
    /// "Previous" even when it was done from the keyboard, AirPods or the app.
    @ObservationIgnored private var history: [String] = []

    /// Changes with each song; the pill swipes when it does.
    var trackKey: String { track.map { "\($0.title)|\($0.artist)" } ?? "" }

    /// Paused for a while: like iPhone, the island lets the song go and settles
    /// back to its resting state. The panel still has the player. Playing
    /// again (or a new song) brings it back at once, since this is worked out
    /// from `isPlaying` and `track` directly.
    var isDormant: Bool {
        !isPlaying && track != nil && track == dormantTrack
    }
    static let dormantAfter: TimeInterval = 5 * 60
    /// The song that has been paused long enough.
    private var dormantTrack: MediaTrack?
    @ObservationIgnored private var pausedTrack: MediaTrack?
    @ObservationIgnored private var pausedSince: Date?
    @ObservationIgnored private var dormancyTimer: Timer?
    private(set) var artwork: NSImage?
    private(set) var accent: Color = .white

    /// Called when a new song starts (after its artwork has loaded).
    @ObservationIgnored var onTrackChange: (@MainActor (MediaTrack) -> Void)?

    private var basePosition: Double = 0
    private var baseDate = Date()
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var artworkLoading = false
    @ObservationIgnored private var artworkAttempts = 0
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The app that's playing, when it comes from the system Now Playing feed
    /// (which also covers browsers). Otherwise the Spotify / Music player.
    private(set) var systemSource: String?
    @ObservationIgnored private var adapter: NowPlayingAdapter?
    @ObservationIgnored private var artworkFingerprint: Int?
    /// The app the current artwork belongs to (system Now Playing).
    @ObservationIgnored private var artworkSource: String?

    /// Whether the system feed is working; while it is, it's the only source.
    private var usesSystem: Bool { adapter?.isHealthy == true }

    /// Bundle ID of whatever is playing, for the panel's header.
    var sourceBundleID: String? { systemSource ?? player?.bundleID }

    private struct Snapshot {
        var stopped: Bool
        var playing: Bool
        var position: Double
        var track: MediaTrack?
        var artworkURL: String?
    }

    // MARK: - Lifecycle

    func start() {
        // Spotify and Music broadcast every change; react on the main queue.
        let players = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            observers.append(players.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let source: PlayerApp = note.name.rawValue.hasPrefix("com.spotify") ? .spotify : .music
                let state = (note.userInfo?["Player State"] as? String)?.lowercased()
                MainActor.assumeIsolated { self?.playerChanged(source, state: state) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.appTerminated(bundleID) }
        })

        // Gentle resync while playing (catches seeks done inside the music app).
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t

        let dormancy = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDormancy() }
        }
        RunLoop.main.add(dormancy, forMode: .common)
        dormancyTimer = dormancy

        // Preferred source: the system Now Playing feed (any app, browsers too).
        let adapter = NowPlayingAdapter()
        adapter.onChange = { [weak self] state in self?.applySystem(state) }
        adapter.onFailure = { [weak self] in
            // Back to asking Spotify and Music directly.
            self?.systemSource = nil
            self?.refreshAll()
        }
        if adapter.start() { self.adapter = adapter }

        refreshAll()
    }

    func stop() {
        adapter?.stop()
    }

    /// Called when the notch opens so the progress bar is exact.
    func syncNow() {
        refreshLoved()
        guard !usesSystem else { return }  // the system feed is already live
        if player == nil { refreshAll() } else { refresh() }
        refreshModes()
    }

    // MARK: - Shuffle, repeat, favourite

    func toggleShuffle() {
        let on = !(shuffleOn ?? false)
        shuffleOn = on
        if usesSystem { adapter?.setShuffle(on); return }
        guard let p = player, p.isRunning else { return }
        switch p {
        case .music: AppleScript.run("tell application id \"com.apple.Music\" to set shuffle enabled to \(on)")
        case .spotify: AppleScript.run("tell application id \"com.spotify.client\" to set shuffling to \(on)")
        }
    }

    /// Off -> all -> one -> off, like Apple Music's button.
    func cycleRepeat() {
        let next: RepeatMode
        switch repeatMode ?? .off {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        repeatMode = next
        if usesSystem {
            adapter?.setRepeat(next == .off ? 1 : (next == .one ? 2 : 3))
            return
        }
        guard let p = player, p.isRunning else { return }
        switch p {
        case .music:
            let value = next == .off ? "off" : (next == .one ? "one" : "all")
            AppleScript.run("tell application id \"com.apple.Music\" to set song repeat to \(value)")
        case .spotify:
            // Spotify's scripting only knows repeat on or off.
            AppleScript.run("tell application id \"com.spotify.client\" to set repeating to \(next != .off)")
        }
    }

    func toggleLoved() {
        guard canLove, track != nil else { return }
        let loved = !(isLoved ?? false)
        isLoved = loved
        AppleScript.run("""
            tell application id "com.apple.Music"
                try
                    set favorited of current track to \(loved)
                on error
                    set loved of current track to \(loved)
                end try
            end tell
            """)
    }

    private func refreshLoved() {
        guard canLove, track != nil, PlayerApp.music.isRunning else {
            if isLoved != nil { isLoved = nil }
            return
        }
        let result = AppleScript.run("""
            tell application id "com.apple.Music"
                try
                    return favorited of current track
                on error
                    return loved of current track
                end try
            end tell
            """)
        let loved = result?.booleanValue
        if isLoved != loved { isLoved = loved }
    }

    /// Reads shuffle and repeat from Spotify or Music (the Now Playing helper
    /// reports them by itself).
    private func refreshModes() {
        guard let p = player, p.isRunning else { return }
        switch p {
        case .music:
            guard let d = AppleScript.run("tell application id \"com.apple.Music\" to return {shuffle enabled, song repeat as string}"),
                  d.numberOfItems >= 2 else { return }
            shuffleOn = d.atIndex(1)?.booleanValue
            switch d.atIndex(2)?.stringValue?.lowercased() {
            case "one": repeatMode = .one
            case "all": repeatMode = .all
            default: repeatMode = .off
            }
        case .spotify:
            guard let d = AppleScript.run("tell application id \"com.spotify.client\" to return {shuffling, repeating}"),
                  d.numberOfItems >= 2 else { return }
            shuffleOn = d.atIndex(1)?.booleanValue
            repeatMode = d.atIndex(2)?.booleanValue == true ? .all : .off
        }
    }


    func position(at date: Date) -> Double {
        let duration = track?.duration ?? 0
        let p = isPlaying ? basePosition + date.timeIntervalSince(baseDate) : basePosition
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }

    // MARK: - Controls

    func playPause() {
        if usesSystem, track != nil {
            basePosition = position(at: Date())
            baseDate = Date()
            isPlaying.toggle()
            adapter?.send(.togglePlayPause)
            return
        }
        guard let p = player, p.isRunning else { return }
        basePosition = position(at: Date())
        baseDate = Date()
        isPlaying.toggle()  // optimistic, feels instant
        AppleScript.run("tell application id \"\(p.bundleID)\" to playpause")
        refreshSoon()
    }

    func next() {
        if usesSystem { adapter?.send(.nextTrack); return }
        guard let p = player, p.isRunning else { return }
        AppleScript.run("tell application id \"\(p.bundleID)\" to next track")
        refreshSoon()
    }

    func previous() {
        lastPreviousPress = Date()
        if usesSystem { adapter?.send(.previousTrack); return }
        guard let p = player, p.isRunning else { return }
        AppleScript.run("tell application id \"\(p.bundleID)\" to previous track")
        refreshSoon()
    }

    func seek(to seconds: Double) {
        if usesSystem {
            basePosition = seconds
            baseDate = Date()
            adapter?.seek(to: seconds)
            return
        }
        guard let p = player, p.isRunning else { return }
        basePosition = seconds
        baseDate = Date()
        AppleScript.run("tell application id \"\(p.bundleID)\" to set player position to \(seconds)")
        refreshSoon()
    }

    func launch(_ app: PlayerApp) {
        guard let url = app.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }

    // MARK: - Events

    private func playerChanged(_ source: PlayerApp, state: String?) {
        guard !usesSystem else { return }
        if state == "stopped" {
            // The app may be quitting: never script it here or it would relaunch.
            if player == source {
                clearState()
                player = nil
                if let other = PlayerApp.allCases.first(where: { $0 != source && $0.isRunning }) {
                    player = other
                    refresh()
                }
            }
            return
        }

        // Whichever app just started playing becomes the one we show.
        if state == "playing" || player == nil {
            player = source
        }
        if player == source { refresh() }
    }

    private func appTerminated(_ bundleID: String?) {
        guard let player, bundleID == player.bundleID else { return }
        clearState()
        self.player = nil
    }

    private func poll() {
        guard !usesSystem else { return }
        if player != nil && isPlaying { refresh() }
    }

    // MARK: - Reading state

    func refresh() {
        guard let p = player else { return }
        guard p.isRunning else {
            clearState()
            player = nil
            return
        }
        guard let snapshot = Self.query(p) else { return }
        apply(snapshot, from: p)
    }

    private func refreshAll() {
        guard !usesSystem else { return }
        var fallback: (PlayerApp, Snapshot)?
        for app in PlayerApp.allCases where app.isRunning {
            guard let s = Self.query(app), !s.stopped else { continue }
            if s.playing {
                player = app
                apply(s, from: app)
                return
            }
            if fallback == nil { fallback = (app, s) }
        }
        if let fallback {
            player = fallback.0
            apply(fallback.1, from: fallback.0)
        }
    }

    private func refreshSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.refresh()
        }
    }

    private func apply(_ s: Snapshot, from app: PlayerApp) {
        guard !s.stopped, let newTrack = s.track else {
            clearState()
            return
        }
        let changed = newTrack.title != track?.title || newTrack.artist != track?.artist
        if changed, settleDirection(for: newTrack, retry: { [weak self] in self?.apply(s, from: app) }) { return }
        track = newTrack
        isPlaying = s.playing
        basePosition = s.position
        baseDate = Date()
        let key = "\(newTrack.title)|\(newTrack.artist)|\(newTrack.album)"
        if changed {
            artworkAttempts = 0
            loadArtwork(for: app, url: s.artworkURL, track: newTrack, key: key, announce: s.playing)
        } else if artwork == nil, !artworkLoading, artworkAttempts < 4 {
            // Spotify often has no artwork link for the first moment of a new
            // song; try again on the next refresh instead of giving up.
            loadArtwork(for: app, url: s.artworkURL, track: newTrack, key: key, announce: false)
        }
    }

    // MARK: - System Now Playing

    /// Applies the merged system state. Times are in microseconds (`--micros`);
    /// the elapsed time was measured at `timestampEpochMicros`.
    private func applySystem(_ state: [String: Any]) {
        guard let title = state["title"] as? String, !title.isEmpty,
              let bundleID = state["bundleIdentifier"] as? String else {
            systemSource = nil
            clearState()
            return
        }
        // Browsers play from helper processes; the parent is the browser itself.
        let source = (state["parentApplicationBundleIdentifier"] as? String) ?? bundleID
        if systemSource != source { systemSource = source }

        let micros: (String) -> Double? = { key in (state[key] as? NSNumber)?.doubleValue }
        let newTrack = MediaTrack(title: title,
                                  artist: state["artist"] as? String ?? "",
                                  album: state["album"] as? String ?? "",
                                  duration: (micros("durationMicros") ?? 0) / 1_000_000)
        let changed = newTrack.title != track?.title || newTrack.artist != track?.artist
        if changed, settleDirection(for: newTrack, retry: { [weak self] in self?.applySystem(state) }) { return }
        if track != newTrack { track = newTrack }

        let playing = state["playing"] as? Bool ?? false
        if isPlaying != playing { isPlaying = playing }
        if let elapsed = micros("elapsedTimeMicros") {
            var position = elapsed / 1_000_000
            if playing, let stamp = micros("timestampEpochMicros") {
                position += Date().timeIntervalSince1970 - stamp / 1_000_000
            }
            basePosition = position
            baseDate = Date()
        }

        // Shuffle and repeat, when the app reports them (1 = off).
        if let shuffle = (state["shuffleMode"] as? NSNumber)?.intValue {
            let on = shuffle >= 2
            if shuffleOn != on { shuffleOn = on }
        }
        if let code = (state["repeatMode"] as? NSNumber)?.intValue {
            let mode: RepeatMode = code == 2 ? .one : (code == 3 ? .all : .off)
            if repeatMode != mode { repeatMode = mode }
        }
        if changed { refreshLoved() }

        let key = "\(newTrack.title)|\(newTrack.artist)|\(newTrack.album)"

        // Browsers and other apps: their thumbnail is usually a video frame or
        // nothing at all, so show the app's own icon instead. Music apps keep
        // the song's artwork.
        if !Self.artworkApps.contains(source) {
            if changed || artworkKey != key || artworkSource != source {
                artworkKey = key
                artworkSource = source
                artworkFingerprint = nil
                let icon = Self.appIcon(for: source)
                artwork = icon
                accent = icon?.notchAccent ?? .white
                if changed { announceSoon(key: key, playing: playing) }
            }
            return
        }
        if artworkSource != source {
            // Switched from a browser to a music app mid-song: load real artwork.
            artworkSource = source
            artworkKey = nil
        }

        if changed || artworkKey != key {
            artworkKey = key
            artworkFingerprint = nil
            artwork = nil
            accent = .white
            if changed { announceSoon(key: key, playing: playing) }
            // Some players publish no artwork (or only later): show the
            // player's icon if nothing has arrived after a moment.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.artworkKey == key, self.artwork == nil,
                      let icon = Self.appIcon(for: source) else { return }
                self.artwork = icon
                self.accent = icon.notchAccent ?? .white
            }
        }

        // The artwork arrives base64-encoded, sometimes a moment after the title.
        if let encoded = state["artworkData"] as? String, encoded.hashValue != artworkFingerprint {
            artworkFingerprint = encoded.hashValue
            if let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                artwork = image
                accent = image.notchAccent ?? .white
            }
        }
    }

    /// Apps whose own artwork is the right picture: the song's cover, the
    /// podcast's or show's art. Everything else (browsers especially) shows its
    /// app icon.
    private static let artworkApps: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV",
    ]

    private static var iconCache: [String: NSImage] = [:]

    private static func appIcon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 256, height: 256)
        iconCache[bundleID] = icon
        return icon
    }

    /// Works out which way the new song should swipe. If that's a change of
    /// direction, it's set first and the song itself follows a moment later
    /// (returns true; `retry` runs on the next pass), so the outgoing title
    /// already knows which way to leave and both slide the same way.
    private func settleDirection(for newTrack: MediaTrack, retry: @escaping @MainActor () -> Void) -> Bool {
        let key = "\(newTrack.title)|\(newTrack.artist)"
        let pressedPrevious = lastPreviousPress.map { Date().timeIntervalSince($0) < 3 } ?? false
        let backInHistory = history.count >= 2 && history[history.count - 2] == key
        let direction = pressedPrevious || backInHistory ? -1 : 1

        if direction != trackDirection {
            trackDirection = direction
            DispatchQueue.main.async {
                MainActor.assumeIsolated { retry() }
            }
            return true
        }

        lastPreviousPress = nil
        if backInHistory {
            history.removeLast()
        } else {
            history.append(key)
            if history.count > 50 { history.removeFirst() }
        }
        return false
    }

    /// Brings the app that's playing to the front (Music, Spotify, the browser...).
    func openSourceApp() {
        guard let id = sourceBundleID, let url = AppLocator.url(for: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }

    /// Runs every second: notes how long the current song has been paused.
    private func checkDormancy() {
        guard let track, !isPlaying else {
            pausedTrack = nil
            pausedSince = nil
            if dormantTrack != nil { dormantTrack = nil }
            return
        }
        if pausedTrack != track {
            pausedTrack = track
            pausedSince = Date()
        }
        if dormantTrack != track, let since = pausedSince,
           Date().timeIntervalSince(since) >= Self.dormantAfter {
            dormantTrack = track
        }
    }

    /// The song-change banner waits a beat so the artwork can arrive first.
    private func announceSoon(key: String, playing: Bool) {
        guard playing else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, self.artworkKey == key, let track = self.track else { return }
            self.onTrackChange?(track)
        }
    }

    private func clearState() {
        track = nil
        isPlaying = false
        artwork = nil
        accent = .white
        artworkKey = nil
        artworkSource = nil
    }

    /// The player's own artwork. (Apple's iTunes catalog was a fallback once;
    /// its terms only allow its artwork next to a store link, so it's gone.)
    private func loadArtwork(for app: PlayerApp, url: String?, track: MediaTrack, key: String, announce: Bool) {
        artworkKey = key
        artworkLoading = true
        artworkAttempts += 1
        Task { [weak self] in
            guard let self else { return }
            var image: NSImage?
            switch app {
            case .music:
                image = Self.musicArtwork()
            case .spotify:
                if let link = url.flatMap(Self.secureURL) {
                    image = await Self.downloadImage(link)
                }
            }
            self.artworkLoading = false
            self.setArtwork(image, key: key, announce: announce)
            // Nothing yet (Spotify's link often appears a moment late, or the
            // catalog was unreachable): ask the player again shortly, paused or not.
            if image == nil, self.artworkAttempts < 4 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.artworkKey == key, self.artwork == nil, self.player == app else { return }
                self.refresh()
            }
        }
    }

    /// `raw data` is the actual JPEG/PNG. Plain `data` returns an AppleScript
    /// "picture" that modern macOS often can't decode, which is why Apple Music
    /// artwork used to go missing.
    private static func musicArtwork() -> NSImage? {
        let result = AppleScript.run("""
            tell application id "com.apple.Music"
                if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
                return ""
            end tell
            """)
        guard let data = result?.data, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    /// macOS blocks plain-http downloads by default; artwork links work over https.
    private static func secureURL(_ link: String) -> URL? {
        guard !link.isEmpty else { return nil }
        let upgraded = link.hasPrefix("http://") ? "https://" + link.dropFirst("http://".count) : link
        return URL(string: upgraded)
    }

    private static func downloadImage(_ url: URL) async -> NSImage? {
        guard let result = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = result.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return NSImage(data: result.0)
    }

    private func setArtwork(_ image: NSImage?, key: String, announce: Bool) {
        guard key == artworkKey else { return }  // a newer song arrived meanwhile
        artwork = image
        accent = image?.notchAccent ?? .white
        if announce, let track { onTrackChange?(track) }
    }

    private static func query(_ app: PlayerApp) -> Snapshot? {
        let source: String
        switch app {
        case .spotify:
            source = """
                tell application id "com.spotify.client"
                    set s to (player state as string)
                    if s is "stopped" then return {s}
                    set t to current track
                    return {s, player position, name of t, artist of t, album of t, (duration of t) / 1000, artwork url of t}
                end tell
                """
        case .music:
            source = """
                tell application id "com.apple.Music"
                    set s to (player state as string)
                    if s is "stopped" then return {s}
                    set t to current track
                    return {s, player position, name of t, artist of t, album of t, duration of t, ""}
                end tell
                """
        }
        guard let d = AppleScript.run(source), d.numberOfItems >= 1 else { return nil }
        let state = d.atIndex(1)?.stringValue?.lowercased() ?? "stopped"
        if state == "stopped" || d.numberOfItems < 7 {
            return Snapshot(stopped: true, playing: false, position: 0, track: nil, artworkURL: nil)
        }
        let track = MediaTrack(title: d.atIndex(3)?.stringValue ?? "Unknown",
                               artist: d.atIndex(4)?.stringValue ?? "",
                               album: d.atIndex(5)?.stringValue ?? "",
                               duration: d.atIndex(6)?.doubleValue ?? 0)
        return Snapshot(stopped: false,
                        playing: state == "playing",
                        position: d.atIndex(2)?.doubleValue ?? 0,
                        track: track,
                        artworkURL: d.atIndex(7)?.stringValue)
    }
}

extension NSImage {
    /// Average color of the artwork, brightened so it reads well on black.
    var notchAccent: Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let average = NSColor(srgbRed: CGFloat(rgba[0]) / 255,
                              green: CGFloat(rgba[1]) / 255,
                              blue: CGFloat(rgba[2]) / 255,
                              alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(nsColor: NSColor(hue: h, saturation: min(s * 1.2, 0.85), brightness: max(b, 0.85), alpha: 1))
    }
}


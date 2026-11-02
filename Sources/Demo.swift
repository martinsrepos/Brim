import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// What Demo Mode is showing right now, for the view model to read in place
/// of the real call, meeting, reminder and download.
@MainActor
@Observable
final class DemoState {
    var isRunning = false
    var call: CallMonitor.Call?
    var callMuted = false
    var event: CalendarMonitor.Event?
    var reminder: ReminderMonitor.Item?
    var download: DownloadMonitor.Active?
    var camera = false
    var microphone = false
}

#if DEMO
/// Demo Mode: every feature of Brim, one after another, with made-up songs,
/// messages, calls, deliveries and devices, for recording the screen. The
/// island, its animations and its glass are the real ones; only the data is
/// staged. Your own notifications wait until it's over, and your settings
/// come back exactly as they were.
///
/// Only in Brim Demo (`./build.sh demo`), never in a release: Run Demo is
/// at the top of its menu bar menu. While it runs:
/// ⌃⌥⌘→ next feature, ⌃⌥⌘Space pause or resume the automatic pace,
/// ⌃⌥⌘⌫ stop.
@MainActor
final class DemoRunner {
    private let vm: NotchViewModel
    private let alerts: AlertCenter
    private var media: MediaController { vm.media }

    private(set) var isRunning = false
    /// Moves on by itself after each step's time (false: only on ⌃⌥⌘→).
    private var autoAdvance = true
    private var nextRequested = false
    private var stopRequested = false
    private var loop: Task<Void, Never>?
    private var stepTask: Task<Void, Never>?
    private var hotKeys: DemoHotKeys?

    // Put back when it ends.
    private var savedTransparency: Double = 0
    private var savedTextScale: CGFloat = 1
    private var savedFollowsVoice = false
    private var savedKeepAwake = false
    private var savedShape: NotchViewModel.ShapeStyle = .automatic
    private var timerIDs: [UUID] = []
    private var shelfFile: URL?
    private var scriptID: UUID?
    private var savedLastScript: String?
    private var trackIndex = 0

    /// Told when it starts and stops (for the menu).
    var onChange: ((Bool) -> Void)?

    init(vm: NotchViewModel, alerts: AlertCenter) {
        self.vm = vm
        self.alerts = alerts
    }

    // MARK: - Running

    func start() {
        guard !isRunning else { return }
        isRunning = true
        autoAdvance = true
        nextRequested = false
        stopRequested = false
        savedTransparency = vm.glassTransparency
        savedTextScale = vm.textScale
        savedFollowsVoice = vm.prompter.followsVoice
        savedKeepAwake = vm.keepAwake.isOn
        savedShape = vm.shapeStyle
        savedLastScript = UserDefaults.standard.string(forKey: "prompter.lastScript")
        timerIDs = []
        trackIndex = 0

        alerts.beginDemo()
        media.beginDemo()
        media.onDemoSkip = { [weak self] step in self?.skipTrack(step) }
        vm.demo.isRunning = true
        vm.isExpanded = false
        Self.prepareIcons()

        let keys = DemoHotKeys { [weak self] key in self?.hotKey(key) }
        keys.start()
        hotKeys = keys
        Diag.event("demo: started")
        onChange?(true)

        loop = Task { @MainActor [weak self] in
            guard let self else { return }
            for step in self.steps {
                if self.stopRequested { break }
                self.nextRequested = false
                self.stepTask = Task { @MainActor in await step.run() }
                let started = Date()
                while !self.stopRequested, !self.nextRequested,
                      !self.autoAdvance || Date().timeIntervalSince(started) < step.seconds {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                self.stepTask?.cancel()
            }
            self.finish()
        }
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
    }

    private func hotKey(_ key: DemoHotKeys.Key) {
        switch key {
        case .next: nextRequested = true
        case .pause: autoAdvance.toggle()
        case .stop: stop()
        }
    }

    /// Everything back as it was.
    private func finish() {
        loop = nil
        stepTask?.cancel()
        stepTask = nil
        hotKeys?.stop()
        hotKeys = nil

        vm.isPreviewingExpanded = false
        vm.ui.showsMirror = false
        if vm.prompter.isActive { vm.prompter.stop() }
        if let scriptID { vm.scripts.remove(scriptID) }
        scriptID = nil
        UserDefaults.standard.set(savedLastScript, forKey: "prompter.lastScript")
        vm.prompter.setFollowsVoice(savedFollowsVoice)
        stopTimers()
        if vm.shapeStyle != savedShape { vm.setShapeStyle(savedShape) }
        vm.demo.camera = false
        vm.demo.microphone = false
        if let shelfFile {
            if let item = vm.shelf.items.first(where: { $0.url.standardizedFileURL == shelfFile.standardizedFileURL }) {
                vm.shelf.remove(item)
            }
            try? FileManager.default.removeItem(at: shelfFile)
        }
        shelfFile = nil
        if vm.keepAwake.isOn != savedKeepAwake { vm.keepAwake.toggle() }
        vm.setGlassTransparency(savedTransparency)
        if vm.textScale != savedTextScale { vm.setTextScale(savedTextScale) }

        vm.demo.call = nil
        vm.demo.callMuted = false
        vm.demo.event = nil
        vm.demo.reminder = nil
        vm.demo.download = nil
        vm.demo.isRunning = false
        vm.liveActivities.setDemo(nil)
        media.onDemoSkip = nil
        media.endDemo()
        alerts.endDemo()

        isRunning = false
        Diag.event("demo: finished")
        onChange?(false)
    }

    // MARK: - The script

    private struct Step {
        let seconds: TimeInterval
        let run: @MainActor () async -> Void
    }

    /// Waits inside a step; false once the step was skipped or stopped.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled
    }

    private var steps: [Step] {
        [
            // 1. The quiet island: the clock and the weather.
            Step(seconds: 3) { [self] in
                media.clearDemoTrack()
            },
            // 2. Music: artwork, title, the waveform, the progress line.
            Step(seconds: 4.5) { [self] in
                showTrack(0, playing: true, position: 42)
                guard await pause(2.6) else { return }
                media.playPause()          // paused: the bars settle into dots
                guard await pause(1.2) else { return }
                media.playPause()
            },
            // 3. Messages, one after another (they stack in the panel later).
            Step(seconds: 6) { [self] in
                post(message("Sara", "Are we still on for dinner tonight? I booked for 8 🍝"))
                guard await pause(2.2) else { return }
                post(message("Leo", "Sending you the photos from Sunday"))
                guard await pause(2.2) else { return }
                post(message("Sara", "Bring the good mood 😄"))
            },
            // 4. Volume, live as it changes.
            Step(seconds: 3) { [self] in
                for level in stride(from: 0.35, through: 0.75, by: 0.0625) {
                    var alert = NotchAlert.volumeBanner(VolumeReading(volume: level, muted: false, device: "Speakers"))
                    alert.isDemo = true
                    alerts.postLive(alert)
                    guard await pause(0.16) else { return }
                }
            },
            // 5. Monitor brightness.
            Step(seconds: 3) { [self] in
                for step in 8...12 {
                    var alert = NotchAlert.brightnessBanner(Double(step) / 16, step: step, display: "Studio Monitor")
                    alert.isDemo = true
                    alerts.postLive(alert)
                    guard await pause(0.2) else { return }
                }
            },
            // 6. The keyboard backlight, step by step.
            Step(seconds: 3) { [self] in
                for level in 2...6 {
                    guard let reading = BacklightReading(ArraySlice([UInt8(8), UInt8(level), UInt8(4)])) else { return }
                    var alert = NotchAlert.backlightBanner(reading)
                    alert.isDemo = true
                    alerts.postLive(alert)
                    guard await pause(0.22) else { return }
                }
            },
            // 7. The microphone muted, then on again.
            Step(seconds: 3) { [self] in
                for muted in [true, false] {
                    var alert = NotchAlert.microphoneBanner(MicrophoneReading(muted: muted, device: "Microphone"))
                    alert.isDemo = true
                    alerts.postLive(alert)
                    guard await pause(1.3) else { return }
                }
            },
            // 8 to 10. AirPods: connected, the case opened next to the Mac,
            // and the case on its own.
            Step(seconds: 5) { [self] in post(BluetoothMonitor.testAlerts()[0]) },
            Step(seconds: 5) { [self] in post(BluetoothMonitor.testAlerts()[1]) },
            Step(seconds: 4) { [self] in post(BluetoothMonitor.testAlerts()[2]) },
            // 11. Other devices: a keyboard connects, a mouse runs low.
            Step(seconds: 5) { [self] in
                post(NotchAlert(symbol: "keyboard", tint: .white, title: "Keyboard", subtitle: "Connected", duration: 2.4))
                guard await pause(2.4) else { return }
                post(NotchAlert(symbol: "computermouse", tint: .orange, title: "Mouse", subtitle: "Low battery",
                                body: "10% remaining", duration: 2.4))
            },
            // 12. The charger, and the charge alert.
            Step(seconds: 5) { [self] in
                post(NotchAlert(symbol: "battery.100.bolt", tint: .green, title: "Charging", subtitle: "64%", duration: 2.4))
                guard await pause(2.4) else { return }
                post(NotchAlert(symbol: "battery.75", tint: .green, title: "Charged to 80%", subtitle: "Unplug to save the battery",
                                duration: 2.4))
            },
            // 13. A delivery beside the music, then clicked into the pill.
            Step(seconds: 7) { [self] in
                vm.liveActivities.setDemo([delivery(stage: 0)])
                guard await pause(2.6) else { return }
                vm.swapActivities()
                guard await pause(1.8) else { return }
                vm.liveActivities.setDemo([delivery(stage: 1)])
            },
            // 14. A live match, and a goal.
            Step(seconds: 6) { [self] in
                vm.liveActivities.setDemo([delivery(stage: 1), match(home: 1, minute: 67)])
                guard await pause(1.6) else { return }
                let scored = match(home: 2, minute: 68)
                vm.liveActivities.setDemo([delivery(stage: 1), scored])
                vm.liveActivities.demoBanner(scored, title: "Goal! Lions 2 – 0 Falcons", body: "68' · City Cup")
            },
            // 15. A timer, in the pill (the music goes to the circle).
            Step(seconds: 5) { [self] in
                vm.liveActivities.setDemo([])
                startTimer { $0.startTimer(minutes: 5) }
                guard await pause(0.6) else { return }
                bringToPill { $0.mode == .timer }
            },
            // 16. Focus and a stopwatch too: the circle's dots count them.
            Step(seconds: 4.5) { [self] in
                startTimer { $0.startFocus() }
                guard await pause(1.2) else { return }
                startTimer { $0.startStopwatch() }
                guard await pause(1.4) else { return }
                vm.swapActivities()
            },
            // 17. A meeting in a few minutes, with Join.
            Step(seconds: 4) { [self] in
                stopTimers()
                vm.demo.event = CalendarMonitor.Event(
                    id: "brim.demo", title: "Design review",
                    start: vm.calendar.lastCheck.addingTimeInterval(4 * 60),
                    end: vm.calendar.lastCheck.addingTimeInterval(34 * 60),
                    color: .blue, location: nil, joinURL: URL(string: "https://example.com/meeting"))
            },
            // 18. A reminder that's due.
            Step(seconds: 4) { [self] in
                vm.demo.event = nil
                vm.demo.reminder = ReminderMonitor.Item(id: "brim.demo", title: "Call the bank",
                                                       due: vm.reminders.lastCheck, color: .orange)
            },
            // 19. A download, filling up, then done.
            Step(seconds: 5) { [self] in
                vm.demo.reminder = nil
                for i in 0...16 {
                    vm.demo.download = DownloadMonitor.Active(name: "Holiday Photos.zip", fraction: Double(i) / 16, count: 1)
                    guard await pause(0.17) else { return }
                }
                vm.demo.download = nil
                post(NotchAlert(symbol: "arrow.down.circle.fill", tint: .blue, title: "Download Complete",
                                body: "Holiday Photos.zip", duration: 2.2))
            },
            // 20. Something arriving over AirDrop.
            Step(seconds: 4.5) { [self] in
                vm.demo.download = nil
                for i in 0...10 {
                    vm.demo.download = DownloadMonitor.Active(name: "Sunset.heic", fraction: Double(i) / 10, count: 1, isAirDrop: true)
                    guard await pause(0.16) else { return }
                }
                vm.demo.download = nil
                post(NotchAlert(symbol: DownloadMonitor.Active.airDropSymbol, tint: .blue, title: "AirDrop Received",
                                body: "Sunset.heic", duration: 2.2))
            },
            // 21. The panel: the player, the Live Activity, the messages.
            Step(seconds: 5) { [self] in
                vm.demo.download = nil
                vm.liveActivities.setDemo([delivery(stage: 1)])
                vm.isPreviewingExpanded = true
            },
            // 22. A file on the shelf.
            Step(seconds: 3.5) { [self] in
                vm.isPreviewingExpanded = true
                addShelfFile()
            },
            // 23. The glass: fully clear, a pause, then slowly down to
            //     solid black, and back.
            Step(seconds: 10) { [self] in
                vm.isPreviewingExpanded = true
                vm.setGlassTransparency(1)
                guard await pause(1.8) else { return }
                let steps = 90
                for i in 0...steps {
                    // Ease in and out over about 4.5 seconds.
                    let x = Double(i) / Double(steps)
                    let eased = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
                    vm.setGlassTransparency(1 - eased)
                    guard await pause(0.05) else { return }
                }
                guard await pause(1.6) else { return }
                for i in 0...20 {
                    vm.setGlassTransparency(savedTransparency * Double(i) / 20)
                    guard await pause(0.04) else { return }
                }
            },
            // 24. Text Size.
            Step(seconds: 5) { [self] in
                vm.setGlassTransparency(savedTransparency)
                vm.isPreviewingExpanded = true
                for scale in [1.12, 1.25] as [CGFloat] {
                    vm.setTextScale(scale)
                    guard await pause(1.6) else { return }
                }
                vm.setTextScale(savedTextScale)
            },
            // 25. The mirror (a placeholder here: no camera), with the
            //     camera's green dot.
            Step(seconds: 4) { [self] in
                if vm.textScale != savedTextScale { vm.setTextScale(savedTextScale) }
                vm.isPreviewingExpanded = true
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { vm.ui.showsMirror = true }
                vm.demo.camera = true
            },
            // 26. The notch style: the island hugs the notch, opens from it,
            //     then floats again.
            Step(seconds: 8.5) { [self] in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { vm.ui.showsMirror = false }
                vm.demo.camera = false
                vm.isPreviewingExpanded = false
                guard await pause(0.8) else { return }
                vm.setShapeStyle(.notch)
                guard await pause(2.4) else { return }
                vm.isPreviewingExpanded = true
                guard await pause(2.6) else { return }
                vm.isPreviewingExpanded = false
                guard await pause(1.2) else { return }
                vm.setShapeStyle(savedShape)
            },
            // 27. A call on its own: the green phone, the waveform, mute,
            //     the microphone's dot.
            Step(seconds: 7.5) { [self] in
                vm.setShapeStyle(savedShape)
                vm.isPreviewingExpanded = false
                vm.liveActivities.setDemo([])
                media.clearDemoTrack()
                vm.demo.call = CallMonitor.Call(appName: "FaceTime", bundleID: "com.apple.FaceTime", started: Date())
                vm.demo.microphone = true
                guard await pause(3.2) else { return }
                vm.toggleCallMute()
                guard await pause(2.8) else { return }
                vm.demo.call = nil
                vm.demo.callMuted = false
                vm.demo.microphone = false
            },
            // 28. The delivery arrives, in the pill.
            Step(seconds: 4) { [self] in
                vm.demo.call = nil
                vm.demo.microphone = false
                vm.liveActivities.setDemo([delivery(stage: 2)])
            },
            // 29. Quiet again; Keep Awake's cup beside the clock.
            Step(seconds: 3.5) { [self] in
                vm.liveActivities.setDemo([])
                if !vm.keepAwake.isOn { vm.keepAwake.toggle() }
            },
            // 30. The teleprompter, scrolling under the camera.
            Step(seconds: 8) { [self] in
                if vm.keepAwake.isOn != savedKeepAwake { vm.keepAwake.toggle() }
                startPrompter()
                guard await pause(1.2) else { return }
                if !vm.prompter.isPlaying { vm.prompter.play() }
            },
            // 31. The lock opening, like after unlocking.
            Step(seconds: 3.5) { [self] in
                if vm.prompter.isActive { vm.prompter.stop() }
                vm.lock.demoUnlock()
            },
            // 32. The music again, and the next song (it swipes in).
            Step(seconds: 4.5) { [self] in
                showTrack(0, playing: true, position: 61)
                guard await pause(1.6) else { return }
                skipTrack(1)
            },
        ]
    }

    private func message(_ from: String, _ text: String) -> NotchAlert {
        NotchAlert(symbol: "message.fill", tint: .green, title: from, body: text,
                   appName: "Messages", bundleID: "brim.demo.messages")
    }

    private func startTimer(_ start: (TimerController) -> Void) {
        let before = Set(vm.timer.items.map(\.id))
        start(vm.timer)
        timerIDs += vm.timer.items.map(\.id).filter { !before.contains($0) }
    }

    private func stopTimers() {
        for id in timerIDs { vm.timer.stop(id) }
        timerIDs = []
    }

    /// Clicks the circle until the activity wanted is in the pill.
    private func bringToPill(_ wanted: (ActivityEntry) -> Bool) {
        for _ in 0..<5 {
            if let first = vm.orderedEntries.first, wanted(first) { return }
            vm.swapActivities()
        }
    }

    // MARK: - Helpers

    private func post(_ alert: NotchAlert) {
        var alert = alert
        alert.isDemo = true
        alert.date = Date()
        alerts.post(alert)
    }

    private struct Song {
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let colors: [NSColor]
    }

    /// Made-up songs, with artwork drawn here.
    private static let songs = [
        Song(title: "Golden Hour Drive", artist: "Lumen Coast", album: "Coastlines", duration: 214,
             colors: [NSColor(red: 0.98, green: 0.55, blue: 0.24, alpha: 1), NSColor(red: 0.85, green: 0.2, blue: 0.45, alpha: 1)]),
        Song(title: "Night Signals", artist: "Neon Atlas", album: "Afterglow", duration: 198,
             colors: [NSColor(red: 0.2, green: 0.35, blue: 0.95, alpha: 1), NSColor(red: 0.55, green: 0.15, blue: 0.75, alpha: 1)]),
        Song(title: "Paper Planes", artist: "Maya Rivers", album: "Small Hours", duration: 187,
             colors: [NSColor(red: 0.2, green: 0.75, blue: 0.6, alpha: 1), NSColor(red: 0.1, green: 0.35, blue: 0.45, alpha: 1)]),
    ]

    private func showTrack(_ index: Int, playing: Bool, position: Double, forward: Bool = true) {
        trackIndex = (index % Self.songs.count + Self.songs.count) % Self.songs.count
        let song = Self.songs[trackIndex]
        media.showDemo(MediaTrack(title: song.title, artist: song.artist, album: song.album, duration: song.duration),
                       artwork: Self.artwork(song.colors), playing: playing, position: position, forward: forward)
    }

    private func skipTrack(_ step: Int) {
        showTrack(trackIndex + step, playing: true, position: 0, forward: step > 0)
    }

    /// Abstract cover art: a soft two-colour gradient with a few circles.
    private static func artwork(_ colors: [NSColor]) -> NSImage {
        NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: -55)
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: 330, y: 300, width: 220, height: 220)).fill()
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 60, y: 70, width: 300, height: 300)).fill()
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: NSRect(x: 380, y: 60, width: 120, height: 120)).fill()
            return true
        }
    }

    // Made-up apps for the Live Activities.
    private static let deliveryApp = "brim.demo.crumb"
    private static let sportsApp = "brim.demo.goalline"

    private static func prepareIcons() {
        IPhoneAppIcons.demoIcons[deliveryApp] = icon(symbol: "takeoutbag.and.cup.and.straw.fill",
                                                     background: NSColor(red: 1, green: 0.6, blue: 0.1, alpha: 1))
        IPhoneAppIcons.demoIcons[sportsApp] = icon(symbol: "soccerball",
                                                   background: NSColor(red: 0.13, green: 0.7, blue: 0.35, alpha: 1))
    }

    /// A square app icon: a white symbol on a colour (iOS rounds the corners).
    private static func icon(symbol: String, background: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 180, height: 180), flipped: false) { rect in
            background.setFill()
            rect.fill()
            let config = NSImage.SymbolConfiguration(pointSize: 92, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                      width: size.width, height: size.height))
            }
            return true
        }
    }

    private func delivery(stage: Int) -> ExternalActivity {
        let lines: [(String, String, String?, Double)] = [
            ("Preparing your order", "Crumb Kitchen is cooking", "18 min", 0.15),
            ("Arriving in 8 min", "Your rider is on the way", "8 min", 0.62),
            ("Order delivered", "Enjoy your meal!", nil, 1),
        ]
        let line = lines[min(stage, 2)]
        var general = ExternalActivity.General(title: line.0, subtitle: line.1, value: line.2, progress: line.3)
        general.isTask = false
        general.finished = stage >= 2
        return ExternalActivity(id: "brim.demo.delivery", bundleID: Self.deliveryApp, appName: "Crumb",
                                fromiPhone: true, started: Date(), relevance: 1, staleDate: nil, endDate: nil,
                                display: .general(general))
    }

    private func match(home: Int, minute: Int) -> ExternalActivity {
        ExternalActivity(id: "brim.demo.match", bundleID: Self.sportsApp, appName: "Goalline",
                         fromiPhone: true, started: Date(), relevance: 0.9, staleDate: nil, endDate: nil,
                         display: .match(ExternalActivity.Match(home: "Lions", away: "Falcons", homeScore: home,
                                                                awayScore: 0, minute: minute, competition: "City Cup")))
    }

    private func addShelfFile() {
        guard shelfFile == nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Brim Demo Notes.txt")
        try? "Brim's shelf keeps files close at hand.\n".write(to: url, atomically: true, encoding: .utf8)
        shelfFile = url
        vm.shelf.add([url])
    }

    private func startPrompter() {
        let script = vm.scripts.newScript()
        scriptID = script.id
        let text = """
        Hi everyone, thanks for joining.
        Today I want to show you Brim, a small app that lives in your Mac's notch.
        It shows your music, your notifications and your Live Activities,
        and it can even be your teleprompter, right under the camera.
        """
        vm.scripts.save(script.id, text: NSAttributedString(string: text))
        vm.scripts.update(script.id) { $0.title = "Brim Demo" }
        vm.prompter.setFollowsVoice(false)
        if let saved = vm.scripts.script(id: script.id) { vm.prompter.start(saved) }
    }
}

/// ⌃⌥⌘→ next, ⌃⌥⌘Space pause or resume, ⌃⌥⌘⌫ stop: only while Demo Mode runs.
final class DemoHotKeys: @unchecked Sendable {
    enum Key { case next, pause, stop }

    private let onPress: @MainActor (Key) -> Void
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef?] = []
    private static let signature: OSType = 0x4252444D   // "BRDM"

    init(onPress: @escaping @MainActor (Key) -> Void) {
        self.onPress = onPress
    }

    func start() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == DemoHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<DemoHotKeys>.fromOpaque(context).takeUnretainedValue()
            let key: Key = id.id == 1 ? .next : id.id == 2 ? .pause : .stop
            MainActor.assumeIsolated { me.onPress(key) }   // Carbon calls this on the main thread
            return noErr
        }, 1, &type, context, &handler)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        for (key, id) in [(kVK_RightArrow, UInt32(1)), (kVK_Space, UInt32(2)), (kVK_Delete, UInt32(3))] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    func stop() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
#endif

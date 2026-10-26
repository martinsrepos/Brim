import AppKit
import SwiftUI
import ServiceManagement
import os

/// Unified logging (view in Console.app, filter by subsystem app.brim.mac).
let appLog = Logger(subsystem: "app.brim.mac", category: "app")

@main
struct BrimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No regular windows: Brim lives in the notch and the menu bar.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var media: MediaController!
    private var alerts: AlertCenter!
    private var vm: NotchViewModel!
    private var notch: NotchWindowController!
    private var mirror: NotificationMirror!
    private var lock: LockMonitor!
    private var timer: TimerController!
    private var calendar: CalendarMonitor!
    private var privacy: PrivacyMonitor!
    private var downloads: DownloadMonitor!
    private var reminders: ReminderMonitor!
    private var calls: CallMonitor!
    private var weather: WeatherMonitor!
    private var keepAwake: KeepAwake!
    private var logitech: LogitechMonitor!
    private var volume: VolumeMonitor!
    private var microphone: MicrophoneMonitor!
    private var brightness: DisplayBrightness!
    private var accessoryBatteries: AccessoryBatteryMonitor?
    private let focus = FocusMonitor()
    private var settings: SettingsWindowController!
    private var power: PowerMonitor?
    private var bluetooth: BluetoothMonitor?
    private var statusItem: NSStatusItem!

    private let defaults = UserDefaults.standard

    private var mirrorEnabled: Bool {
        get { defaults.object(forKey: "mirrorNotifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mirrorNotifications") }
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Before anything reads its settings.
        Self.migrateFromHalo()
        NSApp.mainMenu = Self.editMenu()
        Self.removeKeyboardSoundsLeftovers()

        media = MediaController()
        alerts = AlertCenter()
        lock = LockMonitor()
        lock.start()
        timer = TimerController()
        calendar = CalendarMonitor()
        privacy = PrivacyMonitor()
        downloads = DownloadMonitor()
        reminders = ReminderMonitor()
        calls = CallMonitor()
        weather = WeatherMonitor()
        keepAwake = KeepAwake()
        logitech = LogitechMonitor()
        volume = VolumeMonitor()
        microphone = MicrophoneMonitor()
        brightness = DisplayBrightness()
        vm = NotchViewModel(media: media, alerts: alerts, lock: lock, timer: timer,
                            calendar: calendar, privacy: privacy, downloads: downloads,
                            reminders: reminders, calls: calls, weather: weather, keepAwake: keepAwake,
                            logitech: logitech, volume: volume, microphone: microphone,
                            brightness: brightness)
        notch = NotchWindowController(vm: vm, media: media, alerts: alerts)
        settings = SettingsWindowController(vm: vm)
        QuietState.shared.start()
        QuietState.shared.lockChanged(lock.state)
        lock.onChange = { [weak self] state in
            QuietState.shared.lockChanged(state)
            self?.vm.lockStateChanged(state)
        }
        notch.show()

        // No banner when the song changes: the pill already shows it.
        media.start()

        let post: @MainActor (NotchAlert) -> Void = { [weak self] alert in
            self?.alerts.post(alert)
        }
        power = PowerMonitor(onAlert: post)
        power?.start()
        bluetooth = BluetoothMonitor(onAlert: post)
        bluetooth?.start()
        accessoryBatteries = AccessoryBatteryMonitor(onAlert: post)
        accessoryBatteries?.start()

        mirror = NotificationMirror { [weak self] alert, isNew in
            guard let self else { return }
            // Spotify's and Music's "now playing" notifications repeat what the
            // island already shows, so they're skipped.
            if let sender = alert.bundleID?.lowercased(),
               PlayerApp.allCases.contains(where: { $0.bundleID.lowercased() == sender }) {
                NotificationLog.write("         (not shown: music app, the island already shows the song)")
                return
            }
            // A Focus that silences this app: into the list, no banner.
            if isNew, self.vm.respectFocus, !self.focus.allows(alert.bundleID) {
                NotificationLog.write("         (list only: Focus \u{201C}\(self.focus.name ?? "Focus")\u{201D} is on)")
                self.alerts.remember(alert)
                return
            }
            if isNew {
                self.alerts.post(alert)
                Tones.play(self.vm.notificationSound)
            } else {
                self.alerts.remember(alert)
            }
        }
        mirror.onStatusChange = { [weak self] status in self?.mirrorStatusChanged(status) }
        focus.start()
        if mirrorEnabled { mirror.start() }

        setupActivities()
        setupStatusItem()

        Updater.shared.onFound = { [weak self] release in
            self?.alerts.post(NotchAlert(symbol: "arrow.down.circle.fill", tint: .blue,
                                         title: "Brim \(release.version) Is Available",
                                         body: "Click to update. It takes a few seconds.",
                                         duration: 8, action: .openUpdate))
        }
        Updater.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        vm.editors.saveAll()
        media.stop()  // ends the Now Playing helper process
        calls.stop()  // switches the microphone back on if Brim muted it
        keepAwake.stop()
    }

    // MARK: - Timer, calendar, downloads

    private func setupActivities() {
        alerts.onAction = { [weak self] action in
            switch action {
            case .startFocus: self?.timer.startFocus()
            case .openUpdate: self?.settings.show(pane: .about)
            }
        }
        timer.onFinish = { [weak self] kind in
            let title: String
            var body: String?
            var duration: TimeInterval = 6
            var action: AlertAction?
            switch kind {
            case .focus:
                title = "Focus Complete"
                body = "Time for a \(Int(TimerController.breakMinutes))-minute break."
            case .breakTime:
                title = "Break Over"
                // No automatic next round: you start it when you're back.
                body = "Click to start the next Focus."
                duration = 10
                action = .startFocus
            case .timer, .stopwatch:
                title = "Timer Done"
            }
            self?.alerts.post(NotchAlert(symbol: kind.symbol, tint: kind.tint, title: title, body: body,
                                         duration: duration, action: action))
        }
        // Calendar's own alerts arrive as normal notifications through the
        // mirror (with the Calendar icon), so Brim doesn't post its own: that
        // showed every meeting twice. The circle counts down instead.
        downloads.onFinish = { [weak self] file, isAirDrop in
            self?.alerts.post(NotchAlert(symbol: isAirDrop ? DownloadMonitor.Active.airDropSymbol : "arrow.down.circle.fill",
                                         tint: .blue,
                                         title: isAirDrop ? "AirDrop Received" : "Download Complete",
                                         subtitle: file.lastPathComponent,
                                         appIcon: NSWorkspace.shared.icon(forFile: file.path),
                                         fileURL: file))
        }
        // Keyboard backlight: one banner that follows the level while you
        // keep pressing the keys.
        logitech.onBacklightChange = { [weak self] reading in
            self?.alerts.postLive(.backlightBanner(reading))
        }
        // Low battery, charging and fully charged for every Logitech device.
        logitech.onBatteryAlert = { [weak self] alert in
            self?.alerts.post(alert)
        }
        accessoryBatteries?.skips = { [weak self] name in
            self?.logitech.handlesBattery(of: name) ?? false
        }
        // Volume: the same kind of live banner.
        volume.onChange = { [weak self] reading in
            self?.alerts.postLive(.volumeBanner(reading))
        }
        // Microphone muted or back on (the keyboard's Mute Microphone key,
        // Control Center, Brim's call button).
        microphone.onChange = { [weak self] reading in
            self?.alerts.postLive(.microphoneBanner(reading))
        }
        // Monitor brightness from the keypad buttons (shortcuts) or links.
        brightness.onStep = { [weak self] level in
            guard let self else { return }
            self.alerts.postLive(.brightnessBanner(level, step: self.brightness.stepLevel,
                                                   display: self.brightness.displayName))
        }
        // Teleprompter: banners wait while it reads, and its shortcuts.
        vm.prompter.onActiveChange = { [weak self] active in
            self?.alerts.holdBanners(active)
        }
        vm.prompter.startHotKeys()
        // Shortcuts buttons: a banner when one finishes, or why it didn't.
        vm.shortcuts.onResult = { [weak self] shortcut, error in
            self?.alerts.post(NotchAlert(symbol: error == nil ? shortcut.symbol : "exclamationmark.triangle.fill",
                                         tint: error == nil ? shortcut.tint.top : .orange,
                                         title: shortcut.name,
                                         subtitle: error == nil ? "Done" : nil,
                                         body: error, duration: error == nil ? 2 : 5),
                              remember: false)
        }
        vm.startActivities()
    }

    // MARK: - Notification mirror

    private var previousMirrorStatus: NotificationMirror.Status = .off

    private func mirrorStatusChanged(_ status: NotificationMirror.Status) {
        defer { previousMirrorStatus = status }
        switch status {
        case .needsAccess:
            alerts.post(NotchAlert(symbol: "lock.shield.fill", tint: .orange,
                                   title: "Allow Full Disk Access",
                                   body: "Brim needs it to show your notifications. Turn on Brim in the list that just opened.",
                                   duration: 7),
                        remember: false)
            // Ask at the moment it's needed, once. After that, the menu offers it.
            if !defaults.bool(forKey: "openedFullDiskAccessOnce") {
                defaults.set(true, forKey: "openedFullDiskAccessOnce")
                openFullDiskAccessSettings()
            }
        case .running where previousMirrorStatus == .needsAccess:
            alerts.post(NotchAlert(symbol: "checkmark.circle.fill", tint: .green,
                                   title: "Notifications connected",
                                   body: "New notifications will appear in the notch."),
                        remember: false)
        case .unreadable:
            alerts.post(NotchAlert(symbol: "exclamationmark.triangle.fill", tint: .yellow,
                                   title: "Can't read notifications",
                                   body: "This macOS version stores them differently."),
                        remember: false)
        case .running, .off:
            break
        }
    }

    @objc private func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(NotificationMirror.fullDiskAccessSettings)
    }

    // MARK: - URL scheme: brim://notify?title=...&body=...&icon=...&color=...

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handle)
    }

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "brim" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var query: [String: String] = [:]
        for item in items { query[item.name] = item.value ?? "" }

        switch url.host?.lowercased() {
        case "notify":
            let symbol = query["icon"].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
            alerts.post(NotchAlert(symbol: symbol ?? "bell.fill",
                                   tint: Color.named(query["color"]),
                                   title: query["title"] ?? "Notification",
                                   body: query["body"]))
        case "clear":
            alerts.clearHistory()
        case "timer":
            if let minutes = query["minutes"].flatMap({ Double($0) }), minutes > 0 {
                timer.startTimer(minutes: minutes)
            }
        case "focus":
            timer.startFocus()
        case "stopwatch":
            timer.startStopwatch()
        case "stop-timer":
            timer.stop()
        case "brightness":
            // brim://brightness?step=up, ?step=down, or ?set=0...100
            if let step = query["step"]?.lowercased() {
                brightness.step(up: step != "down")
            } else if let value = query["set"].flatMap({ Double($0) }) {
                brightness.set(value / 100, announce: true)
            }
        case "prompter":
            // brim://prompter?action=toggle|faster|slower|forward|back|stop
            switch query["action"]?.lowercased() ?? "toggle" {
            case "faster": vm.prompter.faster()
            case "slower": vm.prompter.slower()
            case "forward": vm.prompter.nudge(lines: 1)
            case "back": vm.prompter.nudge(lines: -1)
            case "stop": vm.prompter.stop()
            default: vm.prompter.toggle()
            }
        default:
            break
        }
    }

    /// Brim used to be called Halo (bundle ID local.halo.notch). The first
    /// time Brim starts, it takes over Halo's settings and teleprompter
    /// scripts, so nothing has to be set up again. (macOS permissions belong
    /// to the app's identity, so those are asked for again.)
    private static func migrateFromHalo() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromHalo") else { return }
        defaults.set(true, forKey: "migratedFromHalo")
        if let old = defaults.persistentDomain(forName: "local.halo.notch") {
            for (key, value) in old where defaults.object(forKey: key) == nil
                && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
                defaults.set(value, forKey: key)
            }
        }
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldScripts = support.appendingPathComponent("Halo/Scripts", isDirectory: true)
        let newScripts = support.appendingPathComponent("Brim/Scripts", isDirectory: true)
        if files.fileExists(atPath: oldScripts.path), !files.fileExists(atPath: newScripts.path) {
            try? files.createDirectory(at: newScripts.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.moveItem(at: oldScripts, to: newScripts)
        }
    }

    /// Keyboard sounds were tried and removed: their downloaded sound packs
    /// and settings go too.
    private static func removeKeyboardSoundsLeftovers() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "removedKeyboardSounds") else { return }
        defaults.set(true, forKey: "removedKeyboardSounds")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("keySounds.") {
            defaults.removeObject(forKey: key)
        }
        let packs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halo/Soundpacks", isDirectory: true)  // the old name
        try? FileManager.default.removeItem(at: packs)
    }

    // MARK: - Main menu

    /// Brim has no menu bar of its own, but its windows (the script editor,
    /// Settings) still need the usual keys: ⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌘F, ⌘B, ⌘W.
    /// They come from a main menu, even one that never shows.
    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            return item
        }
        submenu("Brim", [item("Quit Brim", #selector(NSApplication.terminate(_:)), "q")])
        submenu("File", [item("Close Window", #selector(NSWindow.performClose(_:)), "w")])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find\u{2026}", #selector(NSTextView.performTextFinderAction(_:)), "f",
                 tag: NSTextFinder.Action.showFindInterface.rawValue),
            item("Find and Replace\u{2026}", #selector(NSTextView.performTextFinderAction(_:)), "f",
                 [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue),
            item("Find Next", #selector(NSTextView.performTextFinderAction(_:)), "g",
                 tag: NSTextFinder.Action.nextMatch.rawValue),
            item("Find Previous", #selector(NSTextView.performTextFinderAction(_:)), "g",
                 [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue),
        ])
        submenu("Format", [item("Bold", #selector(ScriptTextView.toggleBold), "b")])
        return main
    }

    // MARK: - Menu bar item

    /// The SF Symbol "capsule.fill": a solid pill, like the island. As a
    /// template image the menu bar tints it black or white to match the bar,
    /// like the system's own icons.
    /// The app icon's pill as a menu bar glyph: a true capsule (half-circle
    /// ends, straight sides) in the icon's proportions, about 2.8 to 1, rather
    /// than the rounder `capsule.fill` symbol.
    private static func pillIcon() -> NSImage {
        let pill = NSSize(width: 20, height: 7)
        let canvas = NSSize(width: 22, height: 16)
        let image = NSImage(size: canvas, flipped: false) { _ in
            let rect = NSRect(x: (canvas.width - pill.width) / 2, y: (canvas.height - pill.height) / 2,
                              width: pill.width, height: pill.height)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Brim"
        return image
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.pillIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt each time it opens, so every check mark reflects the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Notifications
        let mirrorItem = menuItem("Show Mac Notifications", #selector(toggleMirror(_:)))
        mirrorItem.state = mirrorEnabled ? .on : .off
        menu.addItem(mirrorItem)
        if mirrorEnabled {
            switch mirror.status {
            case .needsAccess:
                menu.addItem(menuItem("Allow Full Disk Access…", #selector(openFullDiskAccessSettings)))
            case .unreadable:
                let item = NSMenuItem(title: "Not readable on this macOS version", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .running, .off:
                break
            }
        }
        let timerItem = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        let timers = NSMenu()
        for minutes in [1, 5, 10, 15, 30, 60] {
            let item = menuItem(minutes == 1 ? "1 Minute" : "\(minutes) Minutes", #selector(startTimerFromMenu(_:)))
            item.tag = minutes
            timers.addItem(item)
        }
        timers.addItem(.separator())
        timers.addItem(menuItem("Focus (25 + 5 min)", #selector(startFocusFromMenu)))
        timers.addItem(menuItem("Stopwatch", #selector(startStopwatchFromMenu)))
        if timer.isActive {
            timers.addItem(.separator())
            timers.addItem(menuItem("Stop", #selector(stopTimerFromMenu)))
        }
        timerItem.submenu = timers
        menu.addItem(timerItem)

        let awakeItem = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
        let awake = NSMenu()
        let off = menuItem("Off", #selector(keepAwakeFromMenu(_:)))
        off.tag = 0
        off.state = keepAwake.isOn ? .off : .on
        awake.addItem(off)
        for (title, minutes) in [("1 Hour", 60), ("4 Hours", 240), ("Until Turned Off", -1)] {
            let item = menuItem(title, #selector(keepAwakeFromMenu(_:)))
            item.tag = minutes
            awake.addItem(item)
        }
        if let until = keepAwake.until {
            awake.addItem(.separator())
            let note = NSMenuItem(title: until == .distantFuture ? "On until turned off"
                                      : "On until \(until.formatted(date: .omitted, time: .shortened))",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            awake.addItem(note)
        }
        awakeItem.submenu = awake
        menu.addItem(awakeItem)
        menu.addItem(.separator())

        menu.addItem(menuItem("Clear Notifications", #selector(clearNotifications)))
        menu.addItem(menuItem("Notification Log…", #selector(openNotificationLog)))
        menu.addItem(.separator())

        // Appearance
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let styles = NSMenu()
        let lockScreen = menuItem("Show on Lock Screen", #selector(toggleLockScreen(_:)))
        lockScreen.state = vm.showOnLockScreen ? .on : .off
        styles.addItem(lockScreen)
        let hideIdle = menuItem("Hide Notch When Idle (screens without a notch)", #selector(toggleHideIdle(_:)))
        hideIdle.state = vm.hideIdleWithoutNotch ? .on : .off
        styles.addItem(hideIdle)
        appearance.submenu = styles
        menu.addItem(appearance)

        let login = menuItem("Launch at Login", #selector(toggleLaunchAtLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(menuItem("Send Test Notification", #selector(sendTest)))
        menu.addItem(.separator())
        if let update = Updater.shared.update {
            menu.addItem(menuItem("Update to Brim \(update.version)…", #selector(openUpdate)))
        } else {
            menu.addItem(menuItem("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(menuItem("Settings…", #selector(openSettings), key: ","))
        menu.addItem(menuItem("Quit Brim", #selector(quit), key: "q"))
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleMirror(_ sender: NSMenuItem) {
        mirrorEnabled.toggle()
        if mirrorEnabled { mirror.start() } else { mirror.stop() }
    }

    @objc private func sendTest() {
        alerts.post(NotchAlert(symbol: "bell.badge.fill", tint: .orange,
                               title: "Test Notification",
                               body: "This is how notifications will look in the notch."))
    }

    @objc private func openNotificationLog() {
        NotificationLog.open()
    }

    @objc private func toggleLockScreen(_ sender: NSMenuItem) {
        vm.setShowOnLockScreen(!vm.showOnLockScreen)
    }

    @objc private func toggleHideIdle(_ sender: NSMenuItem) {
        vm.setHideIdleWithoutNotch(!vm.hideIdleWithoutNotch)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            appLog.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func clearNotifications() {
        alerts.clearAllAnimated()
    }

    @objc private func startTimerFromMenu(_ sender: NSMenuItem) {
        timer.startTimer(minutes: Double(sender.tag))
    }

    @objc private func keepAwakeFromMenu(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: keepAwake.stop()
        case -1: keepAwake.start(for: nil)
        default: keepAwake.start(for: TimeInterval(sender.tag * 60))
        }
    }

    @objc private func startFocusFromMenu() {
        timer.startFocus()
    }

    @objc private func startStopwatchFromMenu() {
        timer.startStopwatch()
    }

    @objc private func stopTimerFromMenu() {
        timer.stop()
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func openUpdate() {
        settings.show(pane: .about)
    }

    @objc private func checkForUpdates() {
        settings.show(pane: .about)
        Updater.shared.checkNow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension Color {
    /// Simple named colors for the URL scheme (color=green, color=red, ...).
    static func named(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        default: return .accentColor
        }
    }
}

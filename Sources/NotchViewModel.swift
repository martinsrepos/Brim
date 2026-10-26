import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

/// What the island is currently showing. One enum instead of a pile of flags,
/// so impossible combinations can't happen.
enum NotchMode: Hashable {
    case idle       // nothing going on: a small black pill
    case live       // a song is loaded: artwork, title, equalizer
    case timer      // a timer, stopwatch or Focus session is running
    case event      // a meeting starts soon
    case download   // a file is downloading
    case reminder   // a reminder is due soon
    case call       // a call is going on (FaceTime, WhatsApp, Zoom...)
    case locked     // screen locked: a lock, like iPhone
    case unlocking  // the lock opens for a moment after you unlock
    case banner     // a notification is showing
    case expanded   // mouse is hovering: player + notifications
    case prompter   // the teleprompter is reading a script
}

struct NotchRadii: Equatable {
    /// Flare where a notch meets the top edge (0 for the floating island).
    var top: CGFloat
    /// Bottom corners of a notch, or the corner radius of the island.
    var bottom: CGFloat
}

@MainActor
@Observable
final class NotchViewModel {
    /// Transparent window hosting the island. Large enough for the biggest
    /// allowed panel plus its shadow.
    static let canvas = CGSize(width: 860, height: 440)

    /// Without a notch, the island floats just below the top edge, like iPhone.
    static let defaultIslandOffset: CGFloat = 10
    static let islandOffsetRange: ClosedRange<CGFloat> = 0...40
    /// Extra width of the compact island while a song is loaded (title + equalizer).
    static let liveExtraWidth: CGFloat = 180
    /// The idle pill's width while it shows the clock or weather, whatever the
    /// pill width is set to, so they never get squeezed.
    static let idleContentWidth: CGFloat = 200

    // Adjustable sizes (Settings window).
    static let defaultPill = CGSize(width: 140, height: 30)
    static let defaultPanel = CGSize(width: 560, height: 194)
    static let pillWidthRange: ClosedRange<CGFloat> = 100...440
    static let pillHeightRange: ClosedRange<CGFloat> = 24...56
    /// Narrow enough to stay compact, wide enough that the player and the
    /// notifications both stay readable.
    static let panelWidthRange: ClosedRange<CGFloat> = 540...900
    /// The player needs about 106pt of height below the header.
    static let panelHeightRange: ClosedRange<CGFloat> = 180...340

    var isExpanded = false

    /// Which displays show an island (Settings).
    enum DisplayChoice: String, CaseIterable {
        case main, pointer, all
        var title: String {
            switch self {
            case .main: return "Main Display"
            case .pointer: return "Display with the Pointer"
            case .all: return "All Displays"
            }
        }
    }
    private(set) var displayChoice: DisplayChoice
    /// The display whose island the pointer is using (it opens and reveals).
    var activeDisplay: CGDirectDisplayID?
    /// Displays where the front app is full screen.
    var fullScreenDisplays: Set<CGDirectDisplayID> = []
    /// A full-screen app or game is in front: the island tucks away above the
    /// screen, like the menu bar does.
    var isFullScreen = false
    /// In full screen, the pointer reached the top edge: the island drops down
    /// until the pointer leaves.
    var isRevealed = false
    /// Settings: keep the panel open while adjusting its size.
    var isPreviewingExpanded = false
    /// The compact pill on screens without a notch.
    private(set) var pillSize: CGSize
    /// The expanded panel (whole island size on screens without a notch).
    private(set) var panelSize: CGSize
    /// Gap between the top of the screen and the island (Settings).
    private(set) var islandOffset: CGFloat
    /// How much wider than the default the notch's wings are (Settings).
    private(set) var wingExtra: CGFloat
    static let wingExtraRange: ClosedRange<CGFloat> = 0...96
    /// Room kept clear on each side of the camera housing, so nothing in the
    /// wings ever touches it.
    static let cameraClearance: CGFloat = 6
    private(set) var closedSize = CGSize(width: 140, height: 30)
    private(set) var hasNotch = false
    private(set) var hideIdleWithoutNotch: Bool

    /// The island's shape (Settings > Appearance): a notch hanging from the
    /// top edge, a floating Dynamic Island-style pill, or whichever suits the
    /// display (a notch on a MacBook, a pill on other screens).
    enum ShapeStyle: String, CaseIterable {
        case automatic, notch, island
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .notch: return "Notch"
            case .island: return "Floating Island"
            }
        }
    }
    private(set) var shapeStyle: ShapeStyle
    /// The height of the display's real notch (0 without one).
    private(set) var hardwareNotchHeight: CGFloat = 0
    @ObservationIgnored private var metricsScreen: NSScreen?
    /// The island is dark Liquid Glass. 0 = solid black, like Dynamic Island;
    /// 1 = clear glass. Anything in between is smoky black glass.
    private(set) var glassTransparency: Double
    private(set) var showOnLockScreen: Bool

    let media: MediaController
    let alerts: AlertCenter
    let lock: LockMonitor
    let timer: TimerController
    let calendar: CalendarMonitor
    let privacy: PrivacyMonitor
    let downloads: DownloadMonitor
    let reminders: ReminderMonitor
    let calls: CallMonitor
    let weather: WeatherMonitor
    let keepAwake: KeepAwake
    let logitech: LogitechMonitor
    let volume: VolumeMonitor
    let microphone: MicrophoneMonitor
    let brightness: DisplayBrightness
    /// Hover and drag state for the views, shared through the environment.
    let ui: NotchUIState
    /// The teleprompter: your scripts, the prompter, the editor windows.
    let scripts = ScriptLibrary()
    let prompter = Prompter()
    let editors = ScriptEditorWindows()
    /// Files dropped on the island, and your Shortcuts buttons.
    let shelf = FileShelf()
    let shortcuts = ShortcutButtons()

    // Feature switches (Settings).
    private(set) var showClock: Bool
    private(set) var showCalendar: Bool
    private(set) var showPrivacyDots: Bool
    private(set) var showDownloads: Bool
    private(set) var showReminders: Bool
    private(set) var showCalls: Bool
    private(set) var showWeather: Bool
    /// Logitech devices: the keyboard backlight banner and battery banners.
    private(set) var showLogitech: Bool
    /// Banner when the output volume changes.
    private(set) var showVolume: Bool
    /// Banner when the microphone is muted or unmuted.
    private(set) var showMicrophoneMute: Bool
    /// The external monitor's brightness: panel slider, keys and banner.
    private(set) var showBrightness: Bool
    /// Notifications from apps a Focus silences go to the list without a banner.
    private(set) var respectFocus: Bool

    init(media: MediaController, alerts: AlertCenter, lock: LockMonitor, timer: TimerController,
         calendar: CalendarMonitor, privacy: PrivacyMonitor, downloads: DownloadMonitor,
         reminders: ReminderMonitor, calls: CallMonitor, weather: WeatherMonitor, keepAwake: KeepAwake,
         logitech: LogitechMonitor, volume: VolumeMonitor, microphone: MicrophoneMonitor,
         brightness: DisplayBrightness) {
        self.media = media
        self.alerts = alerts
        self.lock = lock
        self.timer = timer
        self.calendar = calendar
        self.privacy = privacy
        self.downloads = downloads
        self.reminders = reminders
        self.calls = calls
        self.weather = weather
        self.keepAwake = keepAwake
        self.logitech = logitech
        self.volume = volume
        self.microphone = microphone
        self.brightness = brightness
        self.ui = NotchUIState()
        let defaults = UserDefaults.standard
        self.showClock = defaults.object(forKey: "showClock") as? Bool ?? true
        self.showCalendar = defaults.object(forKey: "showCalendar") as? Bool ?? true
        self.showPrivacyDots = defaults.object(forKey: "showPrivacyDots") as? Bool ?? true
        self.showDownloads = defaults.object(forKey: "showDownloads") as? Bool ?? true
        self.showReminders = defaults.object(forKey: "showReminders") as? Bool ?? true
        self.showCalls = defaults.object(forKey: "showCalls") as? Bool ?? true
        self.showWeather = defaults.object(forKey: "showWeather") as? Bool ?? true
        self.showLogitech = defaults.object(forKey: "showKeyboardBacklight") as? Bool ?? true
        self.showVolume = defaults.object(forKey: "showVolume") as? Bool ?? true
        self.showMicrophoneMute = defaults.object(forKey: "showMicrophoneMute") as? Bool ?? true
        self.showBrightness = defaults.object(forKey: "showBrightness") as? Bool ?? true
        self.respectFocus = defaults.object(forKey: "respectFocus") as? Bool ?? true
        self.hideIdleWithoutNotch = defaults.bool(forKey: "hideIdleWithoutNotch")
        self.shapeStyle = ShapeStyle(rawValue: defaults.string(forKey: "shapeStyle") ?? "") ?? .automatic
        self.displayChoice = DisplayChoice(rawValue: defaults.string(forKey: "displayChoice") ?? "") ?? .main
        // One look now: the old Black style becomes the slider's solid end.
        if defaults.object(forKey: "notchStyle") != nil || defaults.object(forKey: "glassTransparency") == nil {
            if defaults.string(forKey: "notchStyle") != "glass" { defaults.set(0.0, forKey: "glassTransparency") }
            defaults.removeObject(forKey: "notchStyle")
        }
        self.glassTransparency = (defaults.object(forKey: "glassTransparency") as? Double ?? 0).clamped(to: 0...1)
        self.unlockBlackout = lock.state != .unlocked
        self.timerSound = defaults.string(forKey: "timerSound") ?? "Glass"
        self.notificationSound = defaults.string(forKey: "notificationSound") ?? ""
        self.showOnLockScreen = defaults.object(forKey: "showOnLockScreen") as? Bool ?? true
        let offset = defaults.object(forKey: "islandOffset") as? Double
        self.islandOffset = CGFloat(offset ?? Double(Self.defaultIslandOffset)).clamped(to: Self.islandOffsetRange)
        self.wingExtra = CGFloat(UserDefaults.standard.double(forKey: "notchWingExtra")).clamped(to: Self.wingExtraRange)
        let pill = Self.loadSize("pill", default: Self.defaultPill)
        let panel = Self.loadSize("panel", default: Self.defaultPanel)
        self.pillSize = CGSize(width: pill.width.clamped(to: Self.pillWidthRange),
                               height: pill.height.clamped(to: Self.pillHeightRange))
        self.panelSize = CGSize(width: panel.width.clamped(to: Self.panelWidthRange),
                                height: panel.height.clamped(to: Self.panelHeightRange))
        prompter.library = scripts
    }

    // MARK: - Teleprompter

    /// Opens a script in its editor window.
    func openScript(_ script: PromptScript) {
        editors.show(script, library: scripts, prompter: prompter)
    }

    /// Browse for a script file, then edit it.
    func browseForScript() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Script"
        panel.prompt = "Open"
        panel.allowedContentTypes = ScriptLibrary.importTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self else { return }
                self.importScript(at: url)
            }
        }
    }

    /// A file dropped on the panel's teleprompter section.
    func importDroppedScript(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.importScript(at: url) }
            }
        }
        return true
    }

    func importScript(at url: URL) {
        guard ScriptLibrary.importExtensions.contains(url.pathExtension.lowercased()) else {
            alerts.post(NotchAlert(symbol: "doc.questionmark", tint: .orange, title: "Can't Open This File",
                                   body: "Scripts can be text, Markdown, RTF, Word or PDF files.", duration: 4),
                        remember: false)
            return
        }
        guard let script = scripts.importFile(url) else {
            alerts.post(NotchAlert(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Couldn't Read the Script",
                                   body: url.lastPathComponent, duration: 4),
                        remember: false)
            return
        }
        openScript(script)
    }

    private static func loadSize(_ key: String, default value: CGSize) -> CGSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: "\(key)Width")
        let height = defaults.double(forKey: "\(key)Height")
        guard width > 0, height > 0 else { return value }
        return CGSize(width: width, height: height)
    }

    private static func saveSize(_ size: CGSize, as key: String) {
        UserDefaults.standard.set(Double(size.width), forKey: "\(key)Width")
        UserDefaults.standard.set(Double(size.height), forKey: "\(key)Height")
    }

    func setPillSize(_ size: CGSize) {
        pillSize = CGSize(width: size.width.clamped(to: Self.pillWidthRange),
                          height: size.height.clamped(to: Self.pillHeightRange))
        Self.saveSize(pillSize, as: "pill")
        if !(hasNotch && !isIsland) { closedSize = pillSize }
    }

    func setPanelSize(_ size: CGSize) {
        panelSize = CGSize(width: size.width.clamped(to: Self.panelWidthRange),
                           height: size.height.clamped(to: Self.panelHeightRange))
        Self.saveSize(panelSize, as: "panel")
    }

    func setIslandOffset(_ offset: CGFloat) {
        islandOffset = offset.clamped(to: Self.islandOffsetRange)
        UserDefaults.standard.set(Double(islandOffset), forKey: "islandOffset")
    }

    /// The notch wings' width as Settings shows it, in points.
    var wingWidth: CGFloat { wingBase + wingExtra }
    var wingWidthRange: ClosedRange<CGFloat> {
        (wingBase + Self.wingExtraRange.lowerBound)...(wingBase + Self.wingExtraRange.upperBound)
    }
    /// The narrowest wing: room for the artwork or a short time.
    private var wingBase: CGFloat { closedSize.height + 20 }

    func setWingWidth(_ width: CGFloat) {
        wingExtra = (width - wingBase).clamped(to: Self.wingExtraRange)
        UserDefaults.standard.set(Double(wingExtra), forKey: "notchWingExtra")
    }

    func resetSizes() {
        setWingWidth(wingBase)
        setPillSize(Self.defaultPill)
        setPanelSize(Self.defaultPanel)
        setIslandOffset(Self.defaultIslandOffset)
    }

    // MARK: - Settings

    func setDisplayChoice(_ choice: DisplayChoice) {
        displayChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "displayChoice")
    }

    func setGlassTransparency(_ value: Double) {
        glassTransparency = value.clamped(to: 0...1)
        UserDefaults.standard.set(glassTransparency, forKey: "glassTransparency")
    }

    /// How much black lies over the glass: all of it at one end of the
    /// slider, none at the other.
    var glassTintOpacity: Double { unlockBlackout ? 1 : 1 - glassTransparency }

    /// Solid black while the screen is locked (like the lock screen island);
    /// after unlocking it fades to the transparency you chose.
    private(set) var unlockBlackout = false

    func lockStateChanged(_ state: LockMonitor.State) {
        switch state {
        case .locked:
            unlockBlackout = true
            prompter.pause()
        case .unlocking:
            // As soon as it's unlocked: black fades to your transparency while
            // the lock opens.
            guard unlockBlackout else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    withAnimation(.easeInOut(duration: 0.45)) { self?.unlockBlackout = false }
                }
            }
        case .unlocked:
            unlockBlackout = false
        }
    }

    /// The idle pill shows something (clock, weather or the Keep Awake cup).
    var showsIdleContent: Bool {
        isIsland && (showClock || keepAwake.isOn || (showWeather && weather.now != nil))
    }

    // MARK: - Sounds

    /// The tone when a timer ends (one of the Mac's alert sounds).
    private(set) var timerSound: String
    /// A tone Brim plays with each new notification banner ("" = none).
    private(set) var notificationSound: String

    func setTimerSound(_ name: String) {
        timerSound = name
        UserDefaults.standard.set(name, forKey: "timerSound")
        Tones.play(name)
    }

    func setNotificationSound(_ name: String) {
        notificationSound = name
        UserDefaults.standard.set(name, forKey: "notificationSound")
        Tones.play(name)
    }

    func setShapeStyle(_ style: ShapeStyle) {
        shapeStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "shapeStyle")
        if let metricsScreen { updateMetrics(for: metricsScreen) }
    }

    func setHideIdleWithoutNotch(_ hide: Bool) {
        hideIdleWithoutNotch = hide
        UserDefaults.standard.set(hide, forKey: "hideIdleWithoutNotch")
    }

    /// Starts the activity sources that are switched on.
    func startActivities() {
        if showCalendar { calendar.start() }
        if showPrivacyDots { privacy.start() }
        if showDownloads { downloads.start() }
        if showReminders { reminders.start() }
        if showCalls { calls.start() }
        if showWeather { weather.start() }
        if showLogitech { logitech.start() }
        if showVolume { volume.start() }
        if showMicrophoneMute { microphone.start() }
        if showBrightness { brightness.start() }
    }

    func setShowBrightness(_ on: Bool) {
        showBrightness = on
        UserDefaults.standard.set(on, forKey: "showBrightness")
        if on { brightness.start() } else { brightness.stop() }
    }

    func setShowMicrophoneMute(_ on: Bool) {
        showMicrophoneMute = on
        UserDefaults.standard.set(on, forKey: "showMicrophoneMute")
        if on { microphone.start() } else { microphone.stop() }
    }

    func setShowVolume(_ on: Bool) {
        showVolume = on
        UserDefaults.standard.set(on, forKey: "showVolume")
        if on { volume.start() } else { volume.stop() }
    }

    func setShowLogitech(_ on: Bool) {
        showLogitech = on
        UserDefaults.standard.set(on, forKey: "showKeyboardBacklight")
        if on { logitech.start() } else { logitech.stop() }
    }

    func setShowWeather(_ on: Bool) {
        showWeather = on
        UserDefaults.standard.set(on, forKey: "showWeather")
        if on { weather.start() } else { weather.stop() }
    }

    func setRespectFocus(_ on: Bool) {
        respectFocus = on
        UserDefaults.standard.set(on, forKey: "respectFocus")
    }

    func setShowCalls(_ on: Bool) {
        showCalls = on
        UserDefaults.standard.set(on, forKey: "showCalls")
        if on { calls.start() } else { calls.stop() }
    }

    /// The call going on, when calls are switched on.
    var currentCall: CallMonitor.Call? {
        showCalls ? calls.current : nil
    }

    func setShowClock(_ on: Bool) {
        showClock = on
        UserDefaults.standard.set(on, forKey: "showClock")
    }

    func setShowCalendar(_ on: Bool) {
        showCalendar = on
        UserDefaults.standard.set(on, forKey: "showCalendar")
        if on { calendar.start() } else { calendar.stop() }
    }

    func setShowPrivacyDots(_ on: Bool) {
        showPrivacyDots = on
        UserDefaults.standard.set(on, forKey: "showPrivacyDots")
        if on { privacy.start() } else { privacy.stop() }
    }

    func setShowDownloads(_ on: Bool) {
        showDownloads = on
        UserDefaults.standard.set(on, forKey: "showDownloads")
        if on { downloads.start() } else { downloads.stop() }
    }

    func setShowReminders(_ on: Bool) {
        showReminders = on
        UserDefaults.standard.set(on, forKey: "showReminders")
        if on { reminders.start() } else { reminders.stop() }
    }

    /// The reminder due soon, when reminders are switched on.
    var upcomingReminder: ReminderMonitor.Item? {
        showReminders ? reminders.next : nil
    }

    func setShowOnLockScreen(_ show: Bool) {
        showOnLockScreen = show
        UserDefaults.standard.set(show, forKey: "showOnLockScreen")
    }

    // MARK: - State

    /// The resting state when nothing is happening on top. Priority, most
    /// time-sensitive first: a running timer, a meeting within 5 minutes, a
    /// download, the song, a meeting within 15 minutes, then the idle pill.
    var compactMode: NotchMode {
        switch lock.state {
        case .locked: return .locked
        case .unlocking: return .unlocking
        case .unlocked: break
        }
        return orderedEntries.first?.mode ?? .idle
    }

    /// Every activity going on right now, most important first. Each timer
    /// and stopwatch is its own entry, so clicking the circle steps through
    /// them one by one.
    var activityEntries: [ActivityEntry] {
        var list: [ActivityEntry] = []
        // A call comes first, like on iPhone (click the circle to swap).
        if currentCall != nil { list.append(ActivityEntry(mode: .call)) }
        if media.track != nil, !media.isDormant { list.append(ActivityEntry(mode: .live)) }
        // The timer ending soonest first, then the rest, newest first.
        let primaryID = timer.primary?.id
        let timers = timer.items.filter { $0.id == primaryID } + timer.items.filter { $0.id != primaryID }
        list += timers.map { ActivityEntry(mode: .timer, timerID: $0.id) }
        let minutes = upcomingEvent.map { calendar.minutesUntil($0) }
        if let minutes, minutes <= 5 { list.append(ActivityEntry(mode: .event)) }
        if upcomingReminder != nil { list.append(ActivityEntry(mode: .reminder)) }
        if showDownloads, downloads.active != nil { list.append(ActivityEntry(mode: .download)) }
        if let minutes, minutes > 5, minutes <= 15 { list.append(ActivityEntry(mode: .event)) }
        return list
    }

    var activities: [NotchMode] { activityEntries.map(\.mode) }

    /// The entries with the one you chose (by clicking the circle) in front.
    /// Clicking keeps rotating through all of them, music included.
    var orderedEntries: [ActivityEntry] {
        let list = activityEntries
        guard let chosen = chosenPrimary, let index = list.firstIndex(of: chosen) else { return list }
        return Array(list[index...] + list[..<index])
    }

    /// The entry you brought into the pill by clicking the circle.
    private(set) var chosenPrimary: ActivityEntry?

    /// Two things at once, like iPhone: the most important stays in the pill and
    /// the next one splits off into a small circle beside it. Only while the
    /// island is compact; a notification or the panel absorbs the circle again.
    /// Not beside a hardware notch, where that spot belongs to the menu bar.
    var secondaryMode: NotchMode? { secondaryMode(for: mode) }

    func secondaryMode(for mode: NotchMode) -> NotchMode? { secondaryEntry(for: mode)?.mode }

    func secondaryEntry(for mode: NotchMode) -> ActivityEntry? {
        guard lock.state == .unlocked else { return nil }
        switch mode {
        case .live, .timer, .event, .download, .reminder, .call:
            let list = orderedEntries
            return list.count > 1 ? list[1] : nil
        default:
            return nil
        }
    }

    /// On a notch, the second activity sits in an extra wing on the right,
    /// this wide (the island splits off a circle instead).
    var notchExtension: CGFloat { (closedSize.height + 12).rounded() }

    func notchSplit(for mode: NotchMode) -> Bool {
        !isIsland && secondaryEntry(for: mode) != nil
    }

    /// The notch grows only to the right for its extra wing, so the camera
    /// stays covered: the whole shape moves right by half the extension.
    func shapeShift(for mode: NotchMode) -> CGFloat {
        notchSplit(for: mode) ? notchExtension / 2 : 0
    }

    /// The timer the pill shows (when it shows one) and the one in the circle.
    var pillTimerID: UUID? { orderedEntries.first?.timerID }
    var circleTimerID: UUID? { secondaryEntry(for: mode)?.timerID }

    /// Clicking the circle brings its activity into the pill, and the pill's
    /// goes to the circle (with three or more, the next one takes the circle).
    func swapActivities() {
        guard let next = secondaryEntry(for: mode) else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            chosenPrimary = next
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Forgets the choice once that activity is over, so a new one later
    /// doesn't jump ahead of the music.
    func forgetFinishedChoice() {
        if let chosen = chosenPrimary, !activityEntries.contains(chosen) { chosenPrimary = nil }
    }

    /// Space between the pill and the split-off circle (iPhone's proportion).
    var bubbleGap: CGFloat { (closedSize.height * 0.22).rounded() }

    /// How much narrower the pill gets when the circle splits off: the circle
    /// and the gap take the pill's right end, so the island as a whole keeps
    /// its place and width.
    var splitShrink: CGFloat { bubbleGap + closedSize.height }

    /// The next meeting, when calendar events are switched on.
    var upcomingEvent: CalendarMonitor.Event? {
        showCalendar ? calendar.next : nil
    }

    /// Priority: hover panel, the brief unlock animation, a notification, then
    /// the resting state.
    var mode: NotchMode {
        // The prompter takes the island while it's on (not over the lock screen).
        if prompter.isActive && lock.state == .unlocked { return .prompter }
        if isExpanded || isPreviewingExpanded { return .expanded }
        if lock.state == .unlocking { return .unlocking }
        if alerts.current != nil { return .banner }
        return compactMode
    }

    /// What the island on one display shows. With islands on several
    /// displays, only the one the pointer opened shows the panel; the others
    /// keep their resting state. `nil` = the only island.
    func mode(on display: CGDirectDisplayID?) -> NotchMode {
        let shared = mode
        guard shared == .expanded, !isPreviewingExpanded, let display, display != activeDisplay else { return shared }
        if lock.state == .unlocking { return .unlocking }
        if alerts.current != nil { return .banner }
        return compactMode
    }

    /// Hidden above the top edge (full screen, not revealed). A notification
    /// still drops down for its few seconds, like macOS banners do.
    func isTuckedAway(on display: CGDirectDisplayID?, mode: NotchMode) -> Bool {
        let fullScreen = display.map { fullScreenDisplays.contains($0) } ?? isFullScreen
        let revealed = isRevealed && (display == nil || display == activeDisplay)
        return fullScreen && !revealed && mode != .expanded && mode != .banner && mode != .prompter
    }

    var isTuckedAway: Bool { isTuckedAway(on: nil, mode: mode) }

    /// Notification content stays private on the lock screen, like the macOS
    /// default "Show previews: When Unlocked".
    var hidesPreviews: Bool { lock.state == .locked }

    /// Glass everywhere, compact pill included. On the lock screen the island
    /// stays black: glass can't sample what's behind the lock screen layer.
    func usesGlass(for mode: NotchMode, onLockScreen: Bool) -> Bool {
        !onLockScreen
    }

    // MARK: - Geometry

    /// Draw a floating island instead of a notch hanging from the top edge:
    /// the style chosen in Settings, or automatically when there's no
    /// hardware notch.
    var isIsland: Bool {
        switch shapeStyle {
        case .automatic: return !hasNotch
        case .notch: return false
        case .island: return true
        }
    }

    /// Gap between the top of the screen and the shape. A floating island on
    /// a MacBook floats just below the real notch.
    var topInset: CGFloat {
        isIsland ? islandOffset + (hasNotch ? hardwareNotchHeight : 0) : 0
    }

    /// Space reserved at the top of a banner for the hardware notch (none on an island).
    var contentTopInset: CGFloat { isIsland ? 0 : closedSize.height }

    /// Every spacing in the expanded panel. Concentric: artwork corner (12) +
    /// margin (20) = panel corner (32), so the artwork and the panel edge curve
    /// in parallel and the header clears the corners.
    /// The notifications column grows a little with the panel, so the player
    /// keeps most of the extra room but neither side gets squeezed.
    /// The row of buttons under the camera strip on a real notch.
    static let toolRowHeight: CGFloat = 26

    var activityColumnWidth: CGFloat {
        (panelSize.width * 0.36).clamped(to: 190...240).rounded()
    }

    var panelLayout: PanelLayout {
        isIsland
            ? PanelLayout.island
            // On a real notch the header takes two rows: what's playing and
            // the notification count beside the camera, then the buttons
            // below it, so nothing ever sits under the camera housing.
            : cameraGap > 0
                ? PanelLayout(margin: 20, headerTop: 0, headerHeight: closedSize.height + Self.toolRowHeight + 6,
                              contentTop: closedSize.height + Self.toolRowHeight + 6 + 10)
                // A notch drawn on a screen without one: the strip is free.
                : PanelLayout(margin: 20, headerTop: 0, headerHeight: closedSize.height,
                              contentTop: closedSize.height + 10)
    }

    /// Spacing inside the compact pill. The artwork and equalizer each sit
    /// centered in the pill's rounded ends, the same distance from the top,
    /// bottom and side, so they follow the curve instead of crowding it.
    var compactLayout: CompactLayout {
        let h = closedSize.height
        let artwork = (h * 0.6).rounded()
        let equalizer = (h * 0.46).rounded()
        return CompactLayout(
            artworkSize: artwork,
            artworkInset: isIsland ? ((h - artwork) / 2).rounded() : 8,
            artworkCorner: (artwork * 0.28).rounded(),
            equalizerSize: equalizer,
            trailingInset: isIsland ? ((h - equalizer) / 2).rounded() : 8,
            titleSize: min(15, max(12, (h * 0.4).rounded()))
        )
    }

    /// On a notch, the camera sits in the middle, so content goes in "wings" this
    /// wide on each side (Settings > Appearance > Notch Wings).
    var wing: CGFloat { wingWidth }

    /// Whether the compact live state has room for the song title (no camera
    /// in the middle: an island, or a drawn notch on a screen without one).
    var showsTitleWhenCompact: Bool { compactCenterGap == 0 }

    /// Room kept clear in the middle of a compact row: the camera, on a real
    /// notch only.
    var compactCenterGap: CGFloat { !isIsland && hasNotch ? closedSize.width : 0 }

    /// The camera housing plus a little clearance on each side: content in
    /// the camera's row stays outside this. 0 without a real notch.
    var cameraGap: CGFloat { compactCenterGap > 0 ? compactCenterGap + Self.cameraClearance * 2 : 0 }

    /// Body size of the shape for a mode (without a notch's flared top corners).
    func size(for mode: NotchMode) -> CGSize {
        switch mode {
        case .idle:
            return showsIdleContent
                ? CGSize(width: Self.idleContentWidth, height: closedSize.height)
                : CGSize(width: closedSize.width + dotsWing * 2, height: closedSize.height)
        case .live, .timer, .event, .download, .reminder, .call:
            return isIsland
                ? CGSize(width: closedSize.width + Self.liveExtraWidth, height: closedSize.height)
                : CGSize(width: closedSize.width + wing * 2 + (notchSplit(for: mode) ? notchExtension : 0),
                         height: closedSize.height)
        case .locked, .unlocking:
            // Island: just the lock, as wide as the idle clock. Notch: the lock
            // needs a wing beside the camera.
            return isIsland
                ? CGSize(width: Self.idleContentWidth, height: closedSize.height)
                : CGSize(width: closedSize.width + wing * 2, height: closedSize.height)
        case .banner:
            return isIsland
                ? CGSize(width: min(max(panelSize.width - 180, 340), 460), height: 72)
                : CGSize(width: max(closedSize.width + wing * 2 + 140, 380), height: closedSize.height + 66)
        case .expanded:
            // Same content area on both kinds of screen; only the header differs.
            let island = PanelLayout.island
            var contentArea = panelSize.height - island.contentTop - island.margin
            let layout = panelLayout
            if ui.showsScripts {
                // Room for the drop zone and three recent scripts.
                contentArea = max(contentArea, 196)
            }
            if ui.showsMirror {
                // Tall enough for a square mirror as wide as the player area
                // (the panel's width minus the side column), within the window.
                let playerWidth = panelSize.width - layout.margin * 2 - 33 - activityColumnWidth
                let maxArea = Self.canvas.height - 40 - topInset - layout.contentTop - layout.margin
                contentArea = max(contentArea, min(playerWidth, maxArea))
            }
            return CGSize(width: panelSize.width,
                          height: layout.contentTop + contentArea + layout.margin)
        case .prompter:
            // On a notch, the camera's strip sits on top.
            return CGSize(width: prompter.width, height: prompter.height + contentTopInset)
        }
    }

    /// Island: a capsule when compact, growing into a rounded rectangle.
    /// Notch: flared top corners plus rounded bottom corners.
    func radii(for mode: NotchMode) -> NotchRadii {
        if isIsland {
            switch mode {
            case .idle, .live, .timer, .event, .download, .reminder, .call, .locked, .unlocking:
                return NotchRadii(top: 0, bottom: closedSize.height / 2)
            // Banner: 38pt icon with a 17pt margin, about 9 + 17 = 26.
            case .banner:   return NotchRadii(top: 0, bottom: 26)
            case .expanded: return NotchRadii(top: 0, bottom: 32)
            case .prompter: return NotchRadii(top: 0, bottom: 30)
            }
        }
        switch mode {
        case .idle, .live, .timer, .event, .download, .reminder, .call, .locked, .unlocking:
            return NotchRadii(top: 6, bottom: 14)
        case .banner:   return NotchRadii(top: 12, bottom: 24)
        case .expanded: return NotchRadii(top: 18, bottom: 32)
        case .prompter: return NotchRadii(top: 18, bottom: 30)
        }
    }

    /// Everything visible for a mode, measured from the top of the screen.
    /// Used for hover tracking.
    func footprint(for mode: NotchMode) -> CGSize {
        let body = size(for: mode)
        // When split, pill + circle still fill this same width.
        return CGSize(width: body.width + radii(for: mode).top * 2,
                      height: topInset + body.height)
    }

    /// Where the album artwork sits in each state, inside the island. It's one
    /// view that moves between these spots, so it flies from the pill into the
    /// panel and back, like on iPhone.
    func artworkPlacement(for mode: NotchMode) -> ArtworkPlacement? {
        guard media.track != nil else { return nil }
        if mode == .expanded && (ui.showsMirror || ui.showsScripts) { return nil }  // they take the player's place
        switch mode {
        case .live:
            let c = compactLayout
            return ArtworkPlacement(x: c.artworkInset, y: ((closedSize.height - c.artworkSize) / 2).rounded(),
                                    size: c.artworkSize, corner: c.artworkCorner)
        case .expanded:
            let p = panelLayout
            return ArtworkPlacement(x: p.margin, y: p.contentTop,
                                    size: PanelLayout.artworkSize, corner: PanelLayout.artworkCorner)
        case .idle, .timer, .event, .download, .reminder, .call, .locked, .unlocking, .banner, .prompter:
            return nil
        }
    }

    /// The camera and microphone dots live inside the island, so it stays
    /// visible while either is on, even when set to hide when idle.
    func isHiddenWhenIdle(_ mode: NotchMode) -> Bool {
        mode == .idle && isIsland && hideIdleWithoutNotch && !showsPrivacyDot
    }

    /// On a real notch the camera fills the idle shape, so while a dot is on
    /// the notch grows a little on both sides and the dots sit in its right
    /// side, inside the black, never out on the menu bar.
    var dotsWing: CGFloat { !isIsland && hasNotch && showsPrivacyDot ? 30 : 0 }

    var showsPrivacyDot: Bool {
        showPrivacyDots && (privacy.cameraInUse || privacy.microphoneInUse)
    }

    /// Reads the real notch size, or uses a compact floating island.
    /// A real notch keeps its real size when drawn as a notch; everywhere
    /// else (a floating island, or a notch drawn on a screen without one) the
    /// pill size from Settings applies.
    func updateMetrics(for screen: NSScreen) {
        metricsScreen = screen
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            hardwareNotchHeight = top
            closedSize = isIsland ? pillSize : CGSize(width: (screen.frame.width - left.width - right.width).rounded(),
                                                       height: top)
        } else {
            hasNotch = false
            hardwareNotchHeight = 0
            closedSize = pillSize
        }
    }
}

struct PanelLayout: Equatable {
    /// Left, right and bottom margin.
    var margin: CGFloat
    var headerTop: CGFloat
    var headerHeight: CGFloat
    /// Where the player row (and its artwork) starts.
    var contentTop: CGFloat

    static let artworkSize: CGFloat = 84
    static let artworkCorner: CGFloat = 12
    /// The header's round buttons are concentric with the panel's 32pt
    /// corner: 13pt radius, centered 32pt from the top and right edges (19pt
    /// in from each), so the last one nests in the curve.
    static let island = PanelLayout(margin: 19, headerTop: 19, headerHeight: 26, contentTop: 53)
}

struct CompactLayout: Equatable {
    var artworkSize: CGFloat
    var artworkInset: CGFloat
    var artworkCorner: CGFloat
    var equalizerSize: CGFloat
    var trailingInset: CGFloat
    var titleSize: CGFloat
}

struct ArtworkPlacement: Equatable {
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var corner: CGFloat
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Short-lived view state: what the pointer is over, and an in-progress drag.
///
/// Kept in one `@Observable` object instead of `@State`: on recent SDKs `@State`
/// is a macro whose plugin ships only with full Xcode, and Brim should build
/// with the Command Line Tools alone. Observation's macros ship with the compiler.
/// One activity in the island's rotation. Timers carry their id, so several
/// timers are separate entries.
struct ActivityEntry: Hashable {
    let mode: NotchMode
    var timerID: UUID? = nil
}

enum HeaderMenu: Equatable {
    case timer, keepAwake, brightness
    /// The custom timer's digits, in place of the timer menu.
    case customTimer
}

@MainActor
@Observable
final class NotchUIState {
    var hoveredControl: String?
    /// The panel header's slide-out menu that's open, if any.
    var openMenu: HeaderMenu?
    /// The panel shows the camera mirror in place of the player.
    var showsMirror = false
    /// The panel shows the teleprompter's scripts in place of the player.
    var showsScripts = false
    /// A file is being dragged over the teleprompter section.
    var scriptDropTargeted = false
    /// A file is being dragged over the panel (it goes on the shelf).
    var shelfDropTargeted = false
    /// A banner was just clicked open: the window keeps the panel shut until
    /// the pointer leaves.
    var bannerClicked = false
    /// The custom timer being set: hours, minutes, seconds. Starts at the
    /// last custom time you used.
    var customTime: [Int] = {
        let saved = UserDefaults.standard.object(forKey: "lastCustomTimer") as? Int ?? 25 * 60
        return [saved / 3600, (saved % 3600) / 60, saved % 60]
    }()
    /// Which part of the custom time the pointer is over (0 h, 1 m, 2 s).
    var customHover: Int?
    var hoveredAlert: UUID?
    /// The last activity shown in the split-off circle.
    var bubbleEntry: ActivityEntry?
    /// The pointer is over the circle (it grows a little: it can be clicked).
    var hoveringBubble = false
    /// Stacks opened to show each notification.
    var expandedStacks: Set<String> = []
    /// The stack under the pointer (all its notifications), and the one being swiped.
    var hoveredStack: [UUID]?
    var swipingStack: [UUID]?
    /// The notification being swiped with two fingers, and how far.
    var swipingAlert: UUID?
    var swipeOffset: CGFloat = 0
    var progressHovering = false
    var dragFraction: Double?
}

import AppKit
import SwiftUI
import Observation
import EventKit
import CoreAudio
import CoreMediaIO
@preconcurrency import CoreLocation
import IOKit
import IOKit.pwr_mgt

// MARK: - Timer, stopwatch and Focus

/// Countdowns, stopwatches and Focus sessions (25 minutes of focus, then a
/// 5 minute break), as many at once as you like. The island shows the one
/// ending soonest; the panel lists them all.
@MainActor
@Observable
final class TimerController {
    enum Kind: Equatable {
        case timer, stopwatch, focus, breakTime

        var title: String {
            switch self {
            case .timer: return "Timer"
            case .stopwatch: return "Stopwatch"
            case .focus: return "Focus"
            case .breakTime: return "Break"
            }
        }

        var symbol: String {
            switch self {
            case .timer: return "timer"
            case .stopwatch: return "stopwatch"
            case .focus: return "brain.head.profile"
            case .breakTime: return "figure.walk"   // get up and move (the cup is Keep Awake's)
            }
        }

        /// Orange like the iPhone timer; breaks are calmer.
        var tint: Color { self == .breakTime ? .teal : .orange }
    }

    /// One running timer. Times are worked out from dates, so the views'
    /// TimelineViews always read the exact value.
    struct Item: Identifiable, Equatable {
        let id = UUID()
        var kind: Kind
        /// Length of a countdown (0 for a stopwatch), for the progress ring.
        var total: TimeInterval
        var endDate: Date?
        var startDate: Date?
        /// Remaining (countdown) or elapsed (stopwatch) time, while paused.
        var pausedValue: TimeInterval?

        var isPaused: Bool { pausedValue != nil }

        func remaining(at date: Date) -> TimeInterval {
            if let pausedValue { return pausedValue }
            return max(0, endDate?.timeIntervalSince(date) ?? 0)
        }

        func elapsed(at date: Date) -> TimeInterval {
            if let pausedValue { return pausedValue }
            return startDate.map { date.timeIntervalSince($0) } ?? 0
        }

        /// 0...1 for the ring: time used of a countdown, or the seconds hand of a stopwatch.
        func progress(at date: Date) -> Double {
            if kind == .stopwatch { return elapsed(at: date).truncatingRemainder(dividingBy: 60) / 60 }
            guard total > 0 else { return 0 }
            return 1 - remaining(at: date) / total
        }

        private func seconds(at date: Date) -> Int {
            Int((kind == .stopwatch ? elapsed(at: date) : remaining(at: date)).rounded(.up))
        }

        /// Fits the small circle: "1h", "12m", then "9:59".
        func shortDisplay(at date: Date) -> String {
            let s = seconds(at: date)
            if s >= 3600 { return "\(s / 3600)h" }
            if s >= 600 { return "\(s / 60)m" }
            return String(format: "%d:%02d", s / 60, s % 60)
        }

        func display(at date: Date) -> String {
            let s = seconds(at: date)
            let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        }
    }

    static let focusMinutes: Double = 25
    static let breakMinutes: Double = 5

    /// Newest first, so a timer you just added sits at the top of the panel.
    private(set) var items: [Item] = []

    @ObservationIgnored private var ticker: Timer?

    /// Called when a countdown reaches zero.
    @ObservationIgnored var onFinish: (@MainActor (Kind) -> Void)?

    var isActive: Bool { !items.isEmpty }

    /// The one the island shows: the running countdown that ends first, then
    /// any other countdown, then a stopwatch.
    var primary: Item? {
        let now = Date()
        let running = items.filter { $0.kind != .stopwatch && !$0.isPaused }
        if let soonest = running.min(by: { $0.remaining(at: now) < $1.remaining(at: now) }) { return soonest }
        return items.first { $0.kind != .stopwatch } ?? items.first
    }

    /// A timer by id, or the island's main one.
    func item(_ id: UUID?) -> Item? {
        if let id, let match = items.first(where: { $0.id == id }) { return match }
        return primary
    }

    // The island's views read the primary timer through these.
    var kind: Kind? { primary?.kind }
    var isPaused: Bool { primary?.isPaused ?? false }
    func progress(at date: Date) -> Double { primary?.progress(at: date) ?? 0 }
    func display(at date: Date) -> String { primary?.display(at: date) ?? "0:00" }
    func shortDisplay(at date: Date) -> String { primary?.shortDisplay(at: date) ?? "0:00" }

    // MARK: Controls

    func startTimer(minutes: Double) {
        startTimer(seconds: minutes * 60)
    }

    func startTimer(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        add(Item(kind: .timer, total: seconds, endDate: Date().addingTimeInterval(seconds)))
    }

    func startFocus() {
        add(Item(kind: .focus, total: Self.focusMinutes * 60,
                 endDate: Date().addingTimeInterval(Self.focusMinutes * 60)))
    }

    func startStopwatch() {
        add(Item(kind: .stopwatch, total: 0, startDate: Date()))
    }

    /// Pauses or resumes one timer (the island's, when none is named).
    func togglePause(_ id: UUID? = nil) {
        guard let id = id ?? primary?.id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        let now = Date()
        if let paused = item.pausedValue {
            if item.kind == .stopwatch {
                item.startDate = now.addingTimeInterval(-paused)
            } else {
                item.endDate = now.addingTimeInterval(paused)
            }
            item.pausedValue = nil
        } else {
            item.pausedValue = item.kind == .stopwatch ? item.elapsed(at: now) : item.remaining(at: now)
        }
        items[index] = item
    }

    /// Stops one timer, or all of them.
    func stop(_ id: UUID? = nil) {
        if let id {
            items.removeAll { $0.id == id }
        } else {
            items.removeAll()
        }
        if items.isEmpty { stopTicking() }
    }

    // MARK: Internals

    private func add(_ item: Item) {
        items.insert(item, at: 0)
        startTicking()
    }

    private func startTicking() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func check() {
        let now = Date()
        let finished = items.filter { $0.kind != .stopwatch && !$0.isPaused && $0.remaining(at: now) <= 0 }
        guard !finished.isEmpty else { return }
        for item in finished {
            Tones.play(UserDefaults.standard.string(forKey: "timerSound") ?? "Glass")
            onFinish?(item.kind)
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
            if item.kind == .focus {
                // Focus flows into a break automatically, like a Pomodoro.
                items[index] = Item(kind: .breakTime, total: Self.breakMinutes * 60,
                                    endDate: now.addingTimeInterval(Self.breakMinutes * 60))
            } else {
                items.remove(at: index)
            }
        }
        if items.isEmpty { stopTicking() }
    }
}

// MARK: - Calendar

/// The next meeting on any calendar added to the Mac (iCloud, Google,
/// Exchange...), with its video call link when there is one.
@MainActor
@Observable
final class CalendarMonitor {
    struct Event: Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var color: Color
        var location: String?
        var joinURL: URL?
    }

    private(set) var next: Event?
    /// When `next` was last checked; the island reads time from here so it
    /// refreshes its "in 12 min" as the minutes pass.
    private(set) var lastCheck = Date()
    private(set) var isAuthorized = false

    private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var announced: Set<String> = []

    /// Called 5 minutes before an event (`startingNow` false) and as it starts (true).
    @ObservationIgnored var onReminder: (@MainActor (Event, _ startingNow: Bool) -> Void)?

    func start() {
        guard timer == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let granted = (try? await self.store.requestFullAccessToEvents()) ?? false
            self.isAuthorized = granted
            guard granted else { return }
            self.refresh()
            self.observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: self.store, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        next = nil
    }

    /// Minutes until the event starts (negative once it has started).
    func minutesUntil(_ event: Event) -> Double {
        event.start.timeIntervalSince(lastCheck) / 60
    }

    private func refresh() {
        let now = Date()
        lastCheck = now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-10 * 60),
                                                 end: now.addingTimeInterval(60 * 60), calendars: nil)
        let upcoming = store.events(matching: predicate)
            .filter { event in
                guard !event.isAllDay, event.status != .canceled, event.endDate > now,
                      event.startDate > now.addingTimeInterval(-5 * 60) else { return false }
                // Skip meetings you declined.
                let me = event.attendees?.first(where: { $0.isCurrentUser })
                return me?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }

        guard let event = upcoming.first else {
            if next != nil { next = nil }
            return
        }
        let item = Event(id: event.eventIdentifier ?? UUID().uuidString,
                         title: event.title ?? "Event",
                         start: event.startDate,
                         end: event.endDate,
                         color: event.calendar.map { Color(cgColor: $0.cgColor) } ?? .blue,
                         location: event.location,
                         joinURL: Self.meetingLink(in: [event.url?.absoluteString, event.location, event.notes]))
        if next != item { next = item }

        let minutes = item.start.timeIntervalSince(now) / 60
        if minutes <= 5, minutes > 0.5, announced.insert(item.id + "|soon").inserted {
            onReminder?(item, false)
        } else if minutes <= 0.5, minutes > -2, announced.insert(item.id + "|now").inserted {
            onReminder?(item, true)
        }
    }

    /// The first Zoom, Meet, Teams, Webex or FaceTime link in the event.
    static func meetingLink(in texts: [String?]) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                     "webex.com", "facetime.apple.com", "whereby.com"]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if hosts.contains(where: { host.hasSuffix($0) }) { return url }
            }
        }
        return nil
    }
}

// MARK: - Reminders

/// Reminders from the Reminders app that are due soon (with a time, not just
/// a day): from 15 minutes before until you tick them off, for up to an hour
/// after. The Reminders app's own alert at the due time comes through as a
/// normal notification.
@MainActor
@Observable
final class ReminderMonitor {
    struct Item: Equatable {
        var id: String
        var title: String
        var due: Date
        var color: Color
    }

    private(set) var next: Item?
    /// When `next` was last checked; the island reads time from here.
    private(set) var lastCheck = Date()
    private(set) var isAuthorized = false

    /// How early a reminder appears, and how long an overdue one stays.
    static let lead: TimeInterval = 15 * 60
    static let overdueFor: TimeInterval = 60 * 60

    private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// The Reminders app icon, shown in the island.
    static let appIcon: NSImage? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.apple.reminders")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    func start() {
        guard timer == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let granted = (try? await self.store.requestFullAccessToReminders()) ?? false
            self.isAuthorized = granted
            guard granted else { return }
            self.refresh()
            self.observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: self.store, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        next = nil
    }

    /// Minutes until it's due (negative once overdue).
    func minutesUntil(_ item: Item) -> Double {
        item.due.timeIntervalSince(lastCheck) / 60
    }

    /// Ticks the reminder off in the Reminders app.
    func complete(_ item: Item) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            appLog.error("Couldn't complete reminder: \(error.localizedDescription, privacy: .public)")
        }
        if next?.id == item.id { next = nil }
        refresh()
    }

    private func refresh() {
        let now = Date()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: now.addingTimeInterval(-Self.overdueFor),
            ending: now.addingTimeInterval(Self.lead), calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            // Only reminders with a time of day; "today" alone isn't "soon".
            let items: [Item] = (reminders ?? []).compactMap { reminder in
                guard let parts = reminder.dueDateComponents, parts.hour != nil,
                      let due = Calendar.current.date(from: parts) else { return nil }
                return Item(id: reminder.calendarItemIdentifier,
                            title: reminder.title ?? "Reminder",
                            due: due,
                            color: reminder.calendar.map { Color(cgColor: $0.cgColor) } ?? .orange)
            }
            .sorted { $0.due < $1.due }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastCheck = now
                    let first = items.first
                    if self.next != first { self.next = first }
                }
            }
        }
    }
}

// MARK: - Camera and microphone in use

/// The green and orange dots: whether any app is using the camera or the
/// microphone. Reads the same system flags macOS uses for its own indicators;
/// no permission needed.
@MainActor
@Observable
final class PrivacyMonitor {
    private(set) var cameraInUse = false
    private(set) var microphoneInUse = false

    @ObservationIgnored private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        update()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cameraInUse = false
        microphoneInUse = false
    }

    private func update() {
        // Nobody sees the indicators with the displays off.
        guard !QuietState.shared.isDark else { return }
        Diag.count("privacy.update")
        let camera = Self.isCameraRunning()
        let microphone = Self.isMicrophoneRecording()
        if camera != cameraInUse { cameraInUse = camera }
        if microphone != microphoneInUse { microphoneInUse = microphone }
    }

    /// Per-process "is recording" flags (macOS 14.2+). Checking processes rather
    /// than devices matters: AirPods are one device for both playback and the
    /// mic, so "device running" would light up whenever music plays.
    private static func isMicrophoneRecording() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == 0, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &processes) == 0 else { return false }

        for process in processes {
            var inputAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &inputAddress, 0, nil, &runningSize, &running) == 0,
                  running != 0 else { continue }
            // The "Hey Siri" listener keeps an input open; macOS doesn't show a dot for it either.
            if let bundleID = bundleID(of: process), bundleID.contains("corespeech") { continue }
            return true
        }
        return false
    }

    @available(macOS 14.2, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, pointer)
        }
        guard status == 0, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func isCameraRunning() -> Bool {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }

        for device in devices {
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var runningUsed: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil,
                                         UInt32(MemoryLayout<UInt32>.size), &runningUsed, &running) == 0,
               running != 0 {
                return true
            }
        }
        return false
    }
}

// MARK: - Calls

/// A call in progress in a calling app: FaceTime (and iPhone calls answered
/// on the Mac), Zoom, Teams, Webex, Skype, GoTo. Detected by which app is
/// recording from the microphone; only the app is known, never who's calling.
///
/// Messaging apps and browsers aren't treated as calls (they also record voice
/// notes and dictation); when they use the microphone or camera, only the
/// orange or green dot shows.
///
/// Mute switches off the Mac's microphone itself (a supported system setting),
/// so it works with any app, and Brim switches it back on when the call ends.
@MainActor
@Observable
final class CallMonitor {
    struct Call: Equatable {
        var appName: String
        /// The app to bring forward (FaceTime for iPhone calls).
        var bundleID: String
        var started: Date
    }

    private(set) var current: Call?
    private(set) var isMuted = false
    /// False when the microphone in use can't be muted from outside.
    private(set) var canMute = true

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var candidate: (app: CallApp, since: Date)?
    @ObservationIgnored private var lastHeard = Date.distantPast
    @ObservationIgnored private var mutedByBrim = false
    /// Microphones without a mute switch are muted by turning their level to
    /// zero; this is the level to restore.
    @ObservationIgnored private var savedVolume: Float32?

    /// A moment's confirmation, so a flicker of audio doesn't flash a call.
    static let minimumLength: TimeInterval = 1
    /// The microphone can pause for a moment mid-call without ending it.
    static let gracePeriod: TimeInterval = 4

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        update()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endCall()
    }

    func toggleMute() {
        guard current != nil, let device = Self.defaultInputDevice() else { return }
        let mute = !isMuted
        if Self.setMuted(mute, device: device) {
            mutedByBrim = mute
            savedVolume = nil
        } else if mute, let volume = Self.volume(of: device), Self.setVolume(0, device: device) {
            savedVolume = volume
            mutedByBrim = true
        } else if !mute, let volume = savedVolume, Self.setVolume(volume, device: device) {
            savedVolume = nil
            mutedByBrim = false
        } else {
            canMute = false
            return
        }
        isMuted = mute
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Brings the call's window forward.
    func openApp() {
        guard let id = current?.bundleID, let url = AppLocator.url(for: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }

    private func update() {
        let now = Date()
        Diag.count("calls.update")
        // Asking every app whether it's recording is the costly part, so it's
        // only done while some microphone is actually in use.
        let app = Self.anyMicrophoneRunning() ? Self.callAppRecording() : nil
        if app != nil { Diag.count("calls.scan") }
        guard let app else {
            candidate = nil
            if current != nil, now.timeIntervalSince(lastHeard) > Self.gracePeriod { endCall() }
            return
        }
        lastHeard = now
        if let current, current.bundleID == app.openID {
            refreshMuteState()
            return
        }
        if let candidate, candidate.app.openID == app.openID {
            if now.timeIntervalSince(candidate.since) >= Self.minimumLength {
                current = Call(appName: app.name, bundleID: app.openID, started: candidate.since)
                self.candidate = nil
                canMute = true
                refreshMuteState()
            }
        } else {
            candidate = (app, now)
        }
    }

    private func endCall() {
        // Never leave the Mac's microphone switched off after a call.
        if mutedByBrim, let device = Self.defaultInputDevice() {
            if let volume = savedVolume {
                _ = Self.setVolume(volume, device: device)
            } else {
                _ = Self.setMuted(false, device: device)
            }
        }
        mutedByBrim = false
        savedVolume = nil
        if isMuted { isMuted = false }
        if current != nil { current = nil }
    }

    private func refreshMuteState() {
        guard let device = Self.defaultInputDevice() else { return }
        let muted = savedVolume != nil ? true : (Self.isMuted(device: device) ?? false)
        if muted != isMuted { isMuted = muted }
    }

    // MARK: Which app is on a call

    struct CallApp {
        var name: String
        var openID: String
    }

    /// Recording process bundle ID (helpers included) -> the app it belongs
    /// to. Only apps that use the microphone for calls and nothing else.
    private static let callApps: [(prefix: String, openID: String, name: String)] = [
        // FaceTime and iPhone calls run through macOS's own call service.
        ("com.apple.avconferenced", "com.apple.FaceTime", "FaceTime"),
        ("com.apple.FaceTime", "com.apple.FaceTime", "FaceTime"),
        ("com.apple.telephonyutilities", "com.apple.FaceTime", "Phone"),
        ("us.zoom.xos", "us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "com.microsoft.teams2", "Teams"),
        ("Cisco-Systems.Spark", "Cisco-Systems.Spark", "Webex"),
        ("com.webex.meetingmanager", "com.webex.meetingmanager", "Webex"),
        ("com.skype.skype", "com.skype.skype", "Skype"),
        ("com.logmein.goto", "com.logmein.goto", "GoTo"),
    ]

    /// Whether any microphone is open at all: one question per input device,
    /// instead of one per running app.
    private static func anyMicrophoneRunning() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return true }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == 0 else { return true }
        for device in devices {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == 0,
                  streamsSize > 0 else { continue }   // not a microphone
            var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &running, 0, nil, &valueSize, &value) == 0, value != 0 {
                return true
            }
        }
        return false
    }

    private static func callAppRecording() -> CallApp? {
        guard #available(macOS 14.2, *) else { return nil }
        for bundleID in audioProcesses().recording {
            let lower = bundleID.lowercased()
            if let match = callApps.first(where: { lower.hasPrefix($0.prefix.lowercased()) }) {
                return CallApp(name: match.name, openID: match.openID)
            }
        }
        return nil
    }

    /// Bundle IDs of the processes recording from a microphone, and of those
    /// playing sound.
    @available(macOS 14.2, *)
    private static func audioProcesses() -> (recording: [String], playing: [String]) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == 0, size > 0 else { return ([], []) }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &processes) == 0 else { return ([], []) }

        func isRunning(_ process: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == 0 && running != 0
        }

        var recording: [String] = []
        var playing: [String] = []
        for process in processes {
            let input = isRunning(process, kAudioProcessPropertyIsRunningInput)
            let output = isRunning(process, kAudioProcessPropertyIsRunningOutput)
            guard input || output else { continue }
            var idAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(process, &idAddress, 0, nil, &idSize, pointer)
            }
            guard status == 0, let value else { continue }
            let bundleID = value.takeRetainedValue() as String
            if input { recording.append(bundleID) }
            if output { playing.append(bundleID) }
        }
        return (recording, playing)
    }

    // MARK: The Mac's microphone

    private static func defaultInputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == 0,
              device != 0 else { return nil }
        return device
    }

    private static func inputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func isMuted(device: AudioObjectID) -> Bool? {
        var address = inputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == 0 else { return nil }
        return value != 0
    }

    private static func setMuted(_ muted: Bool, device: AudioObjectID) -> Bool {
        var address = inputAddress(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == 0, settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == 0
    }

    private static func volume(of device: AudioObjectID) -> Float32? {
        var address = inputAddress(kAudioDevicePropertyVolumeScalar)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == 0 else { return nil }
        return value
    }

    private static func setVolume(_ volume: Float32, device: AudioObjectID) -> Bool {
        var address = inputAddress(kAudioDevicePropertyVolumeScalar)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == 0, settable.boolValue else { return false }
        var value = volume
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == 0
    }
}

// MARK: - Downloads

/// Files downloading into ~/Downloads, with progress, and AirDrop items being
/// received (they land in Downloads too).
///
/// Safari and Chrome publish download progress so Finder can draw its progress
/// bars; Brim subscribes to the same updates. Partial files (`.download`,
/// `.crdownload`, Firefox's `.part`) are also watched, which covers browsers that
/// don't publish progress and tells when a download finishes.
@MainActor
@Observable
final class DownloadMonitor {
    struct Active: Equatable {
        var name: String
        /// nil when the browser doesn't report progress.
        var fraction: Double?
        var count: Int
        /// Being received over AirDrop rather than downloaded.
        var isAirDrop = false

        var title: String {
            if count > 1 { return isAirDrop ? "\(count) AirDrop Items" : "\(count) Downloads" }
            return name
        }

        /// The glyph inside the progress ring.
        var symbol: String { isAirDrop ? Self.airDropSymbol : "arrow.down" }

        /// SF Symbols' AirDrop glyph, with a stand-in for systems that lack it.
        static let airDropSymbol: String =
            NSImage(systemSymbolName: "airdrop", accessibilityDescription: nil) != nil ? "airdrop" : "wave.3.right"
    }

    private(set) var active: Active?

    @ObservationIgnored private var subscriber: Any?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var partials: [String: URL] = [:]
    @ObservationIgnored private var tracked: [ObjectIdentifier: Tracked] = [:]
    @ObservationIgnored private var finishedAt: [String: Date] = [:]

    private struct Tracked {
        let progress: Progress
        let url: URL
        let name: String
        let isAirDrop: Bool
    }
    @ObservationIgnored private var primed = false
    @ObservationIgnored private var folderWatcher: DispatchSourceFileSystemObject?

    /// Called with the finished file, and whether it came over AirDrop.
    @ObservationIgnored var onFinish: (@MainActor (URL, Bool) -> Void)?

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part"]
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    func start() {
        guard timer == nil else { return }
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            let id = ObjectIdentifier(progress)
            let url = progress.fileURL
            // AirDrop reports its transfers as files being received; browsers
            // as downloading.
            let isAirDrop = progress.fileOperationKind == .receiving
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.track(progress, id: id, url: url, isAirDrop: isAirDrop) }
            }
            return {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.untrack(id) }
                }
            }
        }
        watchFolder()
        poll()
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        timer?.invalidate()
        timer = nil
        folderWatcher?.cancel()
        folderWatcher = nil
        tracked.removeAll()
        partials.removeAll()
        primed = false
        active = nil
    }

    private func track(_ progress: Progress, id: ObjectIdentifier, url: URL?, isAirDrop: Bool) {
        guard let url else { return }
        tracked[id] = Tracked(progress: progress, url: url, name: Self.finalName(of: url), isAirDrop: isAirDrop)
        poll()   // shows it now, and starts following its progress
    }

    /// The sender stopped reporting: finished, or cancelled. Items reported
    /// only through progress (AirDrop) are done if the file is there and the
    /// progress got to the end. Partial files are handled by `poll`.
    private func untrack(_ id: ObjectIdentifier) {
        guard let entry = tracked.removeValue(forKey: id) else { return }
        let isPartial = Self.partialExtensions.contains(entry.url.pathExtension.lowercased())
        if !isPartial, entry.progress.fractionCompleted >= 0.98,
           FileManager.default.fileExists(atPath: entry.url.path) {
            finish(entry.url, isAirDrop: entry.isAirDrop)
        }
        poll()
    }

    /// One banner per file, even if both the progress and the partial file say so.
    private func finish(_ url: URL, isAirDrop: Bool) {
        let name = url.lastPathComponent
        let now = Date()
        finishedAt = finishedAt.filter { now.timeIntervalSince($0.value) < 30 }
        guard finishedAt[name] == nil else { return }
        finishedAt[name] = now
        onFinish?(url, isAirDrop)
    }

    /// The Downloads folder tells Brim when a file is added, renamed or
    /// removed, so it only looks when something happened there. While a
    /// download is going, a check every second follows its progress.
    private func watchFolder() {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            // Can't watch it: fall back to checking every few seconds.
            setPolling(every: 3)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderWatcher = source
    }

    private func setPolling(every interval: TimeInterval?) {
        if let interval {
            guard timer?.timeInterval != interval else { return }
            timer?.invalidate()
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func poll() {
        Diag.count("downloads.poll")
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var current: [String: URL] = [:]
        for url in items where Self.partialExtensions.contains(url.pathExtension.lowercased()) {
            let finalURL = url.deletingPathExtension()
            current[finalURL.lastPathComponent] = finalURL
        }

        // A partial file that disappeared, with the real file now in its place: done.
        if primed {
            for (name, finalURL) in partials where current[name] == nil {
                if FileManager.default.fileExists(atPath: finalURL.path) { finish(finalURL, isAirDrop: false) }
            }
        }
        partials = current
        primed = true

        var fractions: [String: Double] = [:]
        var airDrop: Set<String> = []
        for entry in tracked.values {
            if entry.isAirDrop { airDrop.insert(entry.name) }
            if entry.progress.totalUnitCount > 0 { fractions[entry.name] = entry.progress.fractionCompleted }
        }
        // Downloads reported only through progress (no partial file we recognize).
        var names = Set(current.keys)
        for (name, fraction) in fractions where fraction < 1 { names.insert(name) }
        // AirDrop may not say how big the item is until it starts flowing.
        for name in airDrop where (fractions[name] ?? 0) < 1 { names.insert(name) }

        let sorted = names.sorted()
        let allAirDrop = !sorted.isEmpty && sorted.allSatisfy { airDrop.contains($0) }
        let newValue = sorted.first.map { name in
            Active(name: name.hasPrefix("Unconfirmed") ? "Download" : name,
                   fraction: fractions[name], count: sorted.count, isAirDrop: allAirDrop)
        }
        if newValue != active { active = newValue }
        // Follow progress while something is going; otherwise wait for the folder.
        let busy = !current.isEmpty || !tracked.isEmpty
        setPolling(every: busy ? 1 : (folderWatcher == nil ? 3 : nil))
    }

    private static func finalName(of url: URL) -> String {
        let final = partialExtensions.contains(url.pathExtension.lowercased()) ? url.deletingPathExtension() : url
        return final.lastPathComponent
    }
}


// MARK: - Weather

/// The temperature and sky for the idle clock. No account and no location
/// access: you pick your city in Settings.
///
/// - City search: Apple's geocoder (the one Maps uses; it needs no location
///   permission), with Open-Meteo's place search as a backup.
/// - Weather: Open-Meteo (api.open-meteo.com), with the Norwegian
///   Meteorological Institute (api.met.no) as a backup. Both are free and
///   only receive the city's coordinates.
///
/// Refreshes every 15 minutes. Settings > Weather Now shows the last update,
/// or the exact error when something fails.
@MainActor
@Observable
final class WeatherMonitor {
    struct Now: Equatable {
        var temperature: Int
        var symbol: String
    }

    /// A city from the search, remembered between launches.
    struct Place: Codable, Equatable, Identifiable {
        var name: String
        var region: String?
        var country: String?
        var latitude: Double
        var longitude: Double

        var id: String { "\(latitude),\(longitude)" }
        /// "Milan, Lombardy, Italy"
        var label: String {
            var parts = [name]
            if let region, region != name { parts.append(region) }
            if let country { parts.append(country) }
            return parts.joined(separator: ", ")
        }
    }

    private(set) var now: Now?
    private(set) var place: Place?
    /// What you've typed in Settings, and the matching cities.
    private(set) var query = ""
    private(set) var results: [Place] = []
    /// What's happening, for Settings.
    private(set) var status = "Choose your city"

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: "weatherPlace"),
           let saved = try? JSONDecoder().decode(Place.self, from: data) {
            place = saved
            query = saved.label
        }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        now = nil
    }

    // MARK: Choosing the city

    /// Typing in Settings: searches once you pause. "Milan", "Milano" and
    /// "Milan, Italy" all work.
    func setQuery(_ text: String) {
        query = text
        searchTask?.cancel()
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2, term != place?.label else {
            results = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self else { return }
            self.status = "Searching…"
            let outcome = await Self.search(term)
            guard !Task.isCancelled else { return }
            self.results = outcome.places
            if outcome.places.isEmpty { self.status = outcome.problem }
            else if self.place == nil { self.status = "Pick your city from the list" }
        }
    }

    /// Return in the field: takes the first match (searching first if needed).
    func chooseFirstMatch() {
        if let first = results.first {
            choose(first)
            return
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2, term != place?.label else { return }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            self.status = "Searching…"
            let outcome = await Self.search(term)
            if let first = outcome.places.first {
                self.choose(first)
            } else {
                self.status = outcome.problem
            }
        }
    }

    func choose(_ chosen: Place) {
        place = chosen
        query = chosen.label
        results = []
        if let data = try? JSONEncoder().encode(chosen) {
            UserDefaults.standard.set(data, forKey: "weatherPlace")
        }
        refresh()
    }

    /// Apple first, then Open-Meteo. `problem` says why nothing was found.
    private static func search(_ term: String) async -> (places: [Place], problem: String) {
        let parts = term.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let name = parts.first else { return ([], "Type a city") }
        let hints = parts.dropFirst().map { $0.lowercased() }

        var problems: [String] = []
        do {
            let apple = try await searchApple(term)
            if !apple.isEmpty { return (apple, "") }
        } catch {
            problems.append("Apple: \(error.localizedDescription)")
        }
        do {
            let places = try await searchOpenMeteo(name)
            guard !hints.isEmpty else {
                if !places.isEmpty { return (places, "") }
                return ([], problems.isEmpty ? "No city called \u{201C}\(term)\u{201D}" : problems.joined(separator: " · "))
            }
            // "Milan, Italy": keep the Milans in Italy (or all, if none match).
            let narrowed = places.filter { place in
                let haystack = [place.region, place.country].compactMap { $0?.lowercased() }
                return hints.allSatisfy { hint in haystack.contains { $0.contains(hint) || hint.contains($0) } }
            }
            let result = Array((narrowed.isEmpty ? places : narrowed).prefix(6))
            if !result.isEmpty { return (result, "") }
        } catch {
            problems.append("Open-Meteo: \(error.localizedDescription)")
        }
        appLog.error("Weather city search failed: \(problems.joined(separator: "; "), privacy: .public)")
        return ([], problems.isEmpty ? "No city called \u{201C}\(term)\u{201D}" : problems.joined(separator: " · "))
    }

    private static func searchApple(_ term: String) async throws -> [Place] {
        let marks = try await CLGeocoder().geocodeAddressString(term)
        var seen = Set<String>()
        return marks.compactMap { mark -> Place? in
            guard let location = mark.location else { return nil }
            let name = mark.locality ?? mark.name ?? term
            let place = Place(name: name, region: mark.administrativeArea, country: mark.country,
                              latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            return seen.insert(place.label).inserted ? place : nil
        }
    }

    private struct Places: Decodable {
        struct Result: Decodable {
            let name: String
            let admin1: String?
            let country: String?
            let latitude: Double
            let longitude: Double
        }
        let results: [Result]?
    }

    private static func searchOpenMeteo(_ name: String) async throws -> [Place] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "20"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { return [] }
        let data = try await fetch(url)
        let found = try JSONDecoder().decode(Places.self, from: data)
        return (found.results ?? []).map {
            Place(name: $0.name, region: $0.admin1, country: $0.country,
                  latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    // MARK: Fetching the weather

    func refresh() {
        guard let place else {
            status = "Choose your city"
            return
        }
        Task { await self.load(place) }
    }

    private func load(_ place: Place) async {
        let fahrenheit = Locale.current.measurementSystem == .us
        var problems: [String] = []
        var value: Now?
        do {
            value = try await Self.openMeteo(place, fahrenheit: fahrenheit)
        } catch {
            problems.append("Open-Meteo: \(error.localizedDescription)")
            do {
                value = try await Self.metNorway(place, fahrenheit: fahrenheit)
            } catch {
                problems.append("MET Norway: \(error.localizedDescription)")
            }
        }
        guard let value else {
            appLog.error("Weather failed: \(problems.joined(separator: "; "), privacy: .public)")
            status = problems.joined(separator: " · ")
            return
        }
        if now != value { now = value }
        status = "\(place.name) · \(value.temperature)° · updated \(Date().formatted(date: .omitted, time: .shortened))"
    }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int?
        }
        let current: Current
    }

    private static func openMeteo(_ place: Place, fahrenheit: Bool) async throws -> Now {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let data = try await fetch(url)
        let current = try JSONDecoder().decode(Forecast.self, from: data).current
        return Now(temperature: Int(current.temperature_2m.rounded()),
                   symbol: symbol(code: current.weather_code, day: (current.is_day ?? 1) == 1))
    }

    private struct MetForecast: Decodable {
        struct Properties: Decodable { let timeseries: [Step] }
        struct Step: Decodable { let data: StepData }
        struct StepData: Decodable {
            let instant: Instant
            let next_1_hours: Next?
        }
        struct Instant: Decodable { let details: Details }
        struct Details: Decodable { let air_temperature: Double }
        struct Next: Decodable { let summary: Summary }
        struct Summary: Decodable { let symbol_code: String }
        let properties: Properties
    }

    private static func metNorway(_ place: Place, fahrenheit: Bool) async throws -> Now {
        let address = String(format: "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=%.4f&lon=%.4f",
                             place.latitude, place.longitude)
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        let data = try await fetch(url)
        let forecast = try JSONDecoder().decode(MetForecast.self, from: data)
        guard let first = forecast.properties.timeseries.first else { throw URLError(.cannotParseResponse) }
        let celsius = first.data.instant.details.air_temperature
        let degrees = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return Now(temperature: Int(degrees.rounded()),
                   symbol: symbol(metCode: first.data.next_1_hours?.summary.symbol_code ?? "cloudy"))
    }

    /// GET with a timeout and a User-Agent (MET Norway requires one); any
    /// answer other than 200 is an error with the server's status.
    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Brim/1.0 (macOS notch app; github.com)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Weather", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "server answered \(http.statusCode)"])
        }
        return data
    }

    /// WMO weather codes (Open-Meteo) -> SF Symbols.
    static func symbol(code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 65, 67, 82: return "cloud.heavyrain.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// MET Norway symbol codes ("partlycloudy_day", "heavyrain"...) -> SF Symbols.
    static func symbol(metCode: String) -> String {
        let night = metCode.hasSuffix("_night")
        let base = metCode.replacingOccurrences(of: "_day", with: "")
            .replacingOccurrences(of: "_night", with: "").replacingOccurrences(of: "_polartwilight", with: "")
        if base.contains("thunder") { return "cloud.bolt.rain.fill" }
        if base.contains("snow") || base.contains("sleet") { return "cloud.snow.fill" }
        if base.contains("heavyrain") { return "cloud.heavyrain.fill" }
        if base.contains("lightrain") { return "cloud.drizzle.fill" }
        if base.contains("rain") { return "cloud.rain.fill" }
        if base == "fog" { return "cloud.fog.fill" }
        if base == "clearsky" { return night ? "moon.stars.fill" : "sun.max.fill" }
        if base == "fair" || base == "partlycloudy" { return night ? "cloud.moon.fill" : "cloud.sun.fill" }
        return "cloud.fill"
    }
}

// MARK: - Keep Awake

/// Stops the display from sleeping (like `caffeinate -d`) for a while or until
/// switched off. The island shows a small cup while it's on.
@MainActor
@Observable
final class KeepAwake {
    /// When it switches itself off; `.distantFuture` = until you do.
    private(set) var until: Date?
    var isOn: Bool { until != nil }

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var endTask: Task<Void, Never>?

    /// `duration` nil = until switched off.
    func start(for duration: TimeInterval?) {
        stop()
        var id: IOPMAssertionID = 0
        let created = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                  "Brim: Keep Awake" as CFString, &id)
        guard created == kIOReturnSuccess else { return }
        assertion = id
        until = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        if let duration {
            endTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
    }

    func stop() {
        endTask?.cancel()
        endTask = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        if until != nil { until = nil }
    }

    func toggle() {
        if isOn { stop() } else { start(for: nil) }
    }
}

// MARK: - Keyboard, mouse and trackpad batteries

/// Warns when a wireless keyboard, mouse or trackpad runs low (20%, 10%, 5%),
/// once per step, like iPhone's battery alerts. Reads the levels macOS keeps
/// for Bluetooth accessories; no permission needed.
@MainActor
final class AccessoryBatteryMonitor {
    private let onAlert: @MainActor (NotchAlert) -> Void
    private var timer: Timer?
    /// Devices Brim follows another way (the Logitech keyboard over HID++).
    var skips: (@MainActor (String) -> Bool)?
    /// The lowest step already announced per device.
    private var warned: [String: Int] = [:]
    private static let steps = [20, 10, 5]

    init(onAlert: @escaping @MainActor (NotchAlert) -> Void) {
        self.onAlert = onAlert
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // A first look shortly after launch.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.check()
        }
    }

    private func check() {
        for (name, percent) in Self.levels() {
            if skips?(name) == true { continue }
            if percent > 30 {
                warned[name] = nil  // charged again: warn afresh next time
                continue
            }
            guard let step = Self.steps.last(where: { percent <= $0 }),
                  warned[name].map({ step < $0 }) ?? true else { continue }
            warned[name] = step
            onAlert(NotchAlert(symbol: BluetoothMonitor.symbol(for: name), tint: .red,
                               title: name, subtitle: "Battery Low · \(percent)%",
                               duration: 6, battery: DeviceBattery(single: percent)))
        }
    }

    /// Name -> battery percent for each accessory that reports one.
    private static func levels() -> [String: Int] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var found: [String: Int] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            let name = IORegistryEntryCreateCFProperty(service, "Product" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if let percent, let name, !name.isEmpty {
                found[name] = min(found[name] ?? 100, percent)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found
    }
}

/// The Mac's alert sounds (System Settings > Sound), plus any you've added
/// to ~/Library/Sounds.
enum Tones {
    static let all: [String] = {
        let folders = [URL(fileURLWithPath: "/System/Library/Sounds"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds")]
        let names = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["aiff", "aif", "caf", "wav", "m4a", "mp3"].contains($0.pathExtension.lowercased()) }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
        return Array(Set(names)).sorted()
    }()

    @MainActor
    static func play(_ name: String?) {
        guard let name, !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()  // restart if it's still playing (picking tones quickly)
        sound.play()
    }
}

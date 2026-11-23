import AppKit

/// Do Not Disturb for meetings. When a meeting from Calendar starts and no
/// Focus is on, Brim asks in the island: "Turn on Do Not Disturb?", Yes or
/// Not Now. Yes turns it on, and Brim turns it off again when the meeting
/// ends (only if it was Brim that turned it on, and it's still on).
///
/// macOS has no way for an app to switch Focus itself; Apple only allows it
/// through Shortcuts. So Brim makes two one-action shortcuts, "Brim Focus On"
/// and "Brim Focus Off" (Set Focus › Do Not Disturb › On / Off), signs them
/// with macOS's own `shortcuts sign`, and opens them: the Shortcuts app asks
/// you once to add each one. After that Brim runs them by name.
@MainActor
@Observable
final class MeetingFocus {
    static let onName = "Brim Focus On"
    static let offName = "Brim Focus Off"

    enum Setup: Equatable {
        case checking
        /// Both shortcuts are there.
        case ready
        /// One or both are missing.
        case missing
        /// Waiting for you to click Add Shortcut in the Shortcuts app.
        case adding
        case failed(String)
    }

    private(set) var setup: Setup = .checking

    /// Settings › Live Activities › Do Not Disturb for Meetings.
    private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: "offersMeetingFocus")

    /// Asks the island to show the prompt (set by the app).
    @ObservationIgnored var onPrompt: ((CalendarMonitor.Event) -> Void)?

    /// Meetings already asked about, so each is asked once.
    @ObservationIgnored private var asked: Set<String> = []
    /// The meeting Brim turned Do Not Disturb on for, and when it ends.
    @ObservationIgnored private var turnedOnUntil: Date?
    /// A call was going during that meeting: its end is the meeting's end.
    @ObservationIgnored private var sawCall = false
    @ObservationIgnored private var watcher: Timer?

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: "offersMeetingFocus")
        if on {
            refresh { [weak self] in
                guard let self, self.setup == .missing else { return }
                self.install()
            }
        }
    }

    // MARK: The meeting

    /// Called every few seconds with the next meeting, whether a Focus is
    /// on, and whether a call is going (FaceTime, Zoom, Teams...).
    func check(next event: CalendarMonitor.Event?, focusOn: Bool, callActive: Bool) {
        let now = Date()
        // The meeting Brim silenced is over: Do Not Disturb off again. With a
        // call, that's when the call hangs up, early or late; without one,
        // at the end time in the calendar.
        if let until = turnedOnUntil {
            if callActive { sawCall = true }
            let callEnded = sawCall && !callActive
            let timeUp = !sawCall && now >= until
            if callEnded || timeUp {
                turnedOnUntil = nil
                sawCall = false
                if focusOn { run(Self.offName) }
                Diag.event("Meeting Focus: Do Not Disturb off (\(callEnded ? "the call ended" : "the meeting's end time"))")
            }
        }
        // Only meetings in your calendar are offered Do Not Disturb, not
        // calls on their own.
        guard isEnabled, setup == .ready, !focusOn, let event else { return }
        // From a minute before it starts until it's half over.
        let startsIn = event.start.timeIntervalSince(now)
        let halfway = event.start.addingTimeInterval(event.end.timeIntervalSince(event.start) / 2)
        guard startsIn <= 60, now < halfway, event.end > now, !asked.contains(event.id) else { return }
        asked.insert(event.id)
        onPrompt?(event)
    }

    /// You said yes in the island.
    func turnOn(until end: Date) {
        run(Self.onName)
        turnedOnUntil = end
        sawCall = false
        Diag.event("Meeting Focus: Do Not Disturb on until \(end.formatted(date: .omitted, time: .shortened))")
    }

    // MARK: The shortcuts

    /// Looks up which of the two shortcuts exist.
    func refresh(then done: (() -> Void)? = nil) {
        if setup != .adding { setup = .checking }
        Self.shortcutNames { [weak self] names in
            guard let self else { return }
            let ready = names.contains(Self.onName) && names.contains(Self.offName)
            if ready {
                self.setup = .ready
            } else if self.setup != .adding {
                self.setup = .missing
            }
            done?()
        }
    }

    /// Makes the missing shortcuts and opens them in Shortcuts, one at a
    /// time, waiting for each to be added.
    func install() {
        setup = .adding
        Self.shortcutNames { [weak self] names in
            guard let self else { return }
            let missing = [(Self.onName, true), (Self.offName, false)].filter { !names.contains($0.0) }
            guard !missing.isEmpty else { self.setup = .ready; return }
            self.add(missing[...])
        }
    }

    private func add(_ queue: ArraySlice<(String, Bool)>) {
        guard let first = queue.first else {
            refresh()
            return
        }
        let (name, on) = first
        Task.detached {
            let result = Self.makeSignedShortcut(name: name, on: on)
            await MainActor.run {
                switch result {
                case .failure(let message):
                    self.setup = .failed(message)
                    Diag.event("Meeting Focus: couldn't make \(name): \(message)")
                case .success(let file):
                    // Shortcuts shows the Add Shortcut sheet for it.
                    NSWorkspace.shared.open(file)
                    self.waitForAdd(name, then: queue.dropFirst(), started: Date())
                }
            }
        }
    }

    /// Checks every two seconds, for up to three minutes, until you've added it.
    private func waitForAdd(_ name: String, then rest: ArraySlice<(String, Bool)>, started: Date) {
        Self.shortcutNames { [weak self] names in
            guard let self else { return }
            if names.contains(name) {
                self.add(rest)
            } else if Date().timeIntervalSince(started) > 180 {
                self.setup = .missing
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { self.waitForAdd(name, then: rest, started: started) }
                }
            }
        }
    }

    // MARK: Running /usr/bin/shortcuts

    private func run(_ name: String) {
        Task.detached {
            _ = Self.shortcuts(["run", name])
        }
    }

    /// The names of your shortcuts.
    private static func shortcutNames(_ done: @escaping @MainActor (Set<String>) -> Void) {
        Task.detached {
            let output = shortcuts(["list"]).output
            let names = Set(output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            await MainActor.run { done(names) }
        }
    }

    private enum Made {
        case success(URL)
        case failure(String)
    }

    /// A one-action shortcut, signed by macOS so the Shortcuts app accepts
    /// it: "Set Focus: Do Not Disturb On" (or Off).
    nonisolated private static func makeSignedShortcut(name: String, on: Bool) -> Made {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BrimShortcuts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unsigned = folder.appendingPathComponent("unsigned.shortcut")
        let signed = folder.appendingPathComponent("\(name).shortcut")
        let action: [String: Any] = [
            "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
            "WFWorkflowActionParameters": [
                "Enabled": on ? 1 : 0,
                "FocusModes": ["DisplayString": "Do Not Disturb",
                               "Identifier": "com.apple.donotdisturb.mode.default"],
            ] as [String: Any],
        ]
        let shortcut: [String: Any] = [
            "WFWorkflowActions": [action],
            "WFWorkflowClientVersion": "2607.0.2",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 3_679_049_983 as Int64,   // purple
                               "WFWorkflowIconGlyphNumber": 59_782 as Int64],       // moon
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFQuickActionSurfaces": [Any](),
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowHasOutputFallback": false,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: shortcut, format: .binary, options: 0)
            try data.write(to: unsigned)
        } catch {
            return .failure("couldn't write the shortcut")
        }
        // Signed for this Mac's own use first; for anyone if that's refused.
        for mode in ["people-who-know-me", "anyone"] {
            let result = shortcuts(["sign", "-m", mode, "-i", unsigned.path, "-o", signed.path])
            if result.status == 0, FileManager.default.fileExists(atPath: signed.path) { return .success(signed) }
        }
        return .failure("macOS couldn't sign it")
    }

    @discardableResult
    nonisolated private static func shortcuts(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

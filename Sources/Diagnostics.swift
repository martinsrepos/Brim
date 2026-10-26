import AppKit
import Darwin
import Observation

// MARK: - Counters and events

/// What Brim has been doing, for the diagnostics report: how often each part
/// ran (counters) and the last few hundred notable moments (events). Cheap
/// enough to leave on: a lock and a dictionary bump. Safe from any thread.
///
/// Never records what a notification says, what's playing, or anything you
/// type: only which part of Brim ran, and app bundle IDs where useful.
final class Diag: @unchecked Sendable {   // all state behind `lock`
    static let shared = Diag()

    let launched = Date()
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var events: [(date: Date, text: String)] = []
    private var cpuSamples: [(date: Date, seconds: Double)] = []
    private static let eventLimit = 400
    private static let sampleLimit = 120   // two hours of per-minute samples

    static func count(_ key: String, _ amount: Int = 1) {
        shared.lock.lock()
        shared.counters[key, default: 0] += amount
        shared.lock.unlock()
    }

    static func event(_ text: String) {
        shared.lock.lock()
        shared.events.append((Date(), text))
        if shared.events.count > eventLimit { shared.events.removeFirst(shared.events.count - eventLimit) }
        shared.lock.unlock()
    }

    /// Called once a minute: how much CPU time Brim has used so far.
    static func sampleCPU() {
        let seconds = cpuSeconds()
        shared.lock.lock()
        shared.cpuSamples.append((Date(), seconds))
        if shared.cpuSamples.count > sampleLimit { shared.cpuSamples.removeFirst() }
        shared.lock.unlock()
    }

    func snapshot() -> (counters: [String: Int], events: [(date: Date, text: String)],
                        samples: [(date: Date, seconds: Double)]) {
        lock.lock()
        defer { lock.unlock() }
        return (counters, events, cpuSamples)
    }

    /// User plus system CPU time used by Brim since launch.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Memory Brim really uses (what Activity Monitor shows as Memory).
    static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

// MARK: - Quiet times

/// When the Mac should be left alone: the screen is locked, the displays are
/// asleep, or the Mac is going to sleep. Brim stops talking to hardware
/// (keyboard, mouse, monitor) at those times, because a message to a device
/// can count as activity and wake the screen, and the Apple Watch would then
/// unlock the Mac. Everyday polling also pauses while the displays are dark.
@MainActor
final class QuietState {
    static let shared = QuietState()

    private(set) var isLocked = false
    private(set) var screensAsleep = false
    private(set) var systemAsleep = false
    private var observers: [NSObjectProtocol] = []
    private var sampler: Timer?
    private var wakeHandlers: [@MainActor () -> Void] = []

    /// Runs `handler` each time a quiet time ends (unlocked, displays back on).
    func whenActiveAgain(_ handler: @escaping @MainActor () -> Void) {
        wakeHandlers.append(handler)
    }

    /// Call after any change: tells the waiting parts once the quiet ends.
    private func changed(wasQuiet: Bool) {
        guard wasQuiet, !isQuiet else { return }
        // A moment later, so the displays are really back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            MainActor.assumeIsolated {
                guard !isQuiet else { return }
                for handler in wakeHandlers { handler() }
            }
        }
    }

    /// Locked, displays asleep, or sleeping: no hardware traffic.
    var isQuiet: Bool { isLocked || isDark }

    /// Displays asleep or the Mac sleeping: nobody can see the island.
    var isDark: Bool {
        screensAsleep || systemAsleep   // from macOS's notifications: free to ask 30 times a second
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ action: @escaping @MainActor (QuietState) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let wasQuiet = self.isQuiet
                    action(self)
                    self.changed(wasQuiet: wasQuiet)
                }
            })
        }
        on(NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true; Diag.event("Displays went to sleep") }
        on(NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; Diag.event("Displays woke up") }
        on(NSWorkspace.willSleepNotification) { $0.systemAsleep = true; Diag.event("Mac going to sleep") }
        on(NSWorkspace.didWakeNotification) { $0.systemAsleep = false; Diag.event("Mac woke up") }

        Diag.sampleCPU()
        let t = Timer(timeInterval: 60, repeats: true) { _ in Diag.sampleCPU() }
        RunLoop.main.add(t, forMode: .common)
        sampler = t
    }

    func lockChanged(_ state: LockMonitor.State) {
        let locked = state != .unlocked
        guard locked != isLocked else { return }
        let wasQuiet = isQuiet
        isLocked = locked
        Diag.event(locked ? "Screen locked" : "Screen unlocked")
        changed(wasQuiet: wasQuiet)
    }
}

// MARK: - Report

/// Builds the report Settings › Create Diagnostics Report saves.
@MainActor
enum DiagnosticsReport {
    /// Measures CPU for a few seconds, gathers everything, writes the file
    /// and shows it in Finder.
    static func create(vm: NotchViewModel, completion: @escaping @MainActor (URL?) -> Void) {
        let cpuStart = Diag.cpuSeconds()
        let wallStart = Date()
        let settings = settingsSummary(vm)
        let devices = deviceSummary(vm)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let liveCPU = (Diag.cpuSeconds() - cpuStart) / Date().timeIntervalSince(wallStart) * 100
            let power = await Task.detached { powerSummary() }.value
            let text = compose(liveCPU: liveCPU, settings: settings, devices: devices, power: power)
            let url = save(text)
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            completion(url)
        }
    }

    private static func compose(liveCPU: Double, settings: [String], devices: [String], power: String) -> String {
        let (counters, events, samples) = Diag.shared.snapshot()
        let now = Date()
        let uptime = now.timeIntervalSince(Diag.shared.launched)
        let minutes = max(uptime / 60, 1)
        var out: [String] = []
        func line(_ s: String = "") { out.append(s) }

        line("Brim diagnostics report")
        line("Created: \(now.formatted(date: .abbreviated, time: .standard))")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        line("Brim \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        line("Mac: \(sysctl("hw.model") ?? "?"), \(ProcessInfo.processInfo.activeProcessorCount) cores")
        line("Brim running for \(duration(uptime))")
        line()

        line("== Resources ==")
        let total = Diag.cpuSeconds()
        line(String(format: "CPU now (5 s average): %.1f%%", liveCPU))
        line(String(format: "CPU since launch: %.0f s total, %.2f%% on average", total, total / uptime * 100))
        if let memory = Diag.memoryFootprint() {
            line(String(format: "Memory: %.0f MB", Double(memory) / 1_048_576))
        }
        line("CPU per minute, last hour (oldest first):")
        let recent = samples.suffix(61)
        var perMinute: [String] = []
        for (a, b) in zip(recent, recent.dropFirst()) {
            let span = b.date.timeIntervalSince(a.date)
            guard span > 0 else { continue }
            perMinute.append(String(format: "%.1f", (b.seconds - a.seconds) / span * 100))
        }
        line(perMinute.isEmpty ? "  (not enough samples yet)" : "  " + perMinute.joined(separator: " "))
        line()

        line("== Activity since launch (count, per minute) ==")
        for (key, value) in counters.sorted(by: { $0.key < $1.key }) {
            line(String(format: "%@  %ld  (%.1f/min)", key.padding(toLength: 34, withPad: " ", startingAt: 0),
                        value, Double(value) / minutes))
        }
        line()

        line("== Settings ==")
        settings.forEach { line("  " + $0) }
        line()
        line("== Devices and displays ==")
        devices.forEach { line("  " + $0) }
        line()
        line("== Power (wakes, sleeps and what's keeping the Mac awake) ==")
        line(power)
        line()
        line("== Recent events (oldest first) ==")
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        for event in events { line("\(formatter.string(from: event.date))  \(event.text)") }
        line()
        line("No notification text, song titles or typing are included in this report.")
        return out.joined(separator: "\n")
    }

    private static func settingsSummary(_ vm: NotchViewModel) -> [String] {
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        return [
            "Show on: \(vm.displayChoice.title), shape: \(vm.shapeStyle.title)",
            "Transparency: \(Int(vm.glassTransparency * 100))%",
            "Pill: \(Int(vm.pillSize.width))x\(Int(vm.pillSize.height)), panel: \(Int(vm.panelSize.width))x\(Int(vm.panelSize.height)), distance \(Int(vm.islandOffset))",
            "Clock \(onOff(vm.showClock)), meetings \(onOff(vm.showCalendar)), dots \(onOff(vm.showPrivacyDots)), downloads \(onOff(vm.showDownloads))",
            "Reminders \(onOff(vm.showReminders)), calls \(onOff(vm.showCalls)), weather \(onOff(vm.showWeather)), Respect Focus \(onOff(vm.respectFocus))",
            "Volume \(onOff(vm.showVolume)), microphone \(onOff(vm.showMicrophoneMute)), brightness \(onOff(vm.showBrightness)), Logitech \(onOff(vm.showLogitech))",
            "On lock screen: \(onOff(vm.showOnLockScreen)), Keep Awake: \(onOff(vm.keepAwake.isOn))",
        ]
    }

    private static func deviceSummary(_ vm: NotchViewModel) -> [String] {
        var lines: [String] = []
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            lines.append("Display \(id): \(screen.localizedName), \(Int(screen.frame.width))x\(Int(screen.frame.height)) pt"
                         + (CGDisplayIsBuiltin(id) != 0 ? ", built in" : "")
                         + (screen.safeAreaInsets.top > 0 ? ", notch" : ""))
        }
        lines.append("Brightness: \(vm.brightness.isAvailable ? vm.brightness.methodName : "not available")")
        switch vm.logitech.state {
        case .connected(let names): lines.append("Logitech: \(names.joined(separator: ", "))")
        case .needsAccess: lines.append("Logitech: waiting for Input Monitoring")
        case .searching: lines.append("Logitech: none connected")
        case .off: lines.append("Logitech: off")
        }
        lines.append("Quiet now: locked \(QuietState.shared.isLocked), dark \(QuietState.shared.isDark)")
        return lines
    }

    /// From `pmset`: the recent wakes and sleeps with their reasons, and the
    /// power assertions (what's keeping the Mac or its displays awake now).
    nonisolated private static func powerSummary() -> String {
        let log = shell("/usr/bin/pmset -g log | /usr/bin/grep -E ' (Wake|DarkWake|Sleep|Display is turned (on|off))' | /usr/bin/tail -n 60")
        let assertions = shell("/usr/bin/pmset -g assertions")
        return "Recent power events:\n\(log.isEmpty ? "(none)" : log)\n\nAssertions now:\n\(assertions)"
    }

    nonisolated private static func shell(_ command: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return "(couldn't run)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // read before waiting
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func save(_ text: String) -> URL? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Brim")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let url = folder.appendingPathComponent("Brim-Diagnostics-\(formatter.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            appLog.error("Diagnostics: couldn't save the report: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}

import AppKit
import SwiftUI
import IOKit
import IOKit.hid
import Observation

// Logitech devices over HID++: the keyboard backlight banner (MX Keys
// family) and battery banners for every Logitech device paired over
// Bluetooth (keyboards, MX Master mice, the MX Dialpad...).
//
// The keyboard handles its backlight in firmware, so macOS never hears about
// it. Brim asks the devices themselves over Logitech's HID++ 2.0 protocol.
//
// Protocol, checked in Solaar (lib/logitech_receiver) and OpenLogi
// (crates/openlogi-hidpp/src/feature/backlight.rs):
//   - A keyboard paired straight over Bluetooth LE exposes HID++ on vendor
//     page 0xFF43, usage 0x0202, long reports only:
//     [0x11, 0xFF, feature index, function << 4 | software ID, 16 bytes].
//   - Root (index 0), function 0 getFeature(id hi, id lo) -> index, type, version.
//   - Backlight2 (0x1982), function 2 getBacklightInfo -> levels, level, status.
//     Event 0 (backlightInfoEvent) has the same layout.
//   - Errors: [0x11, device, 0xFF, feature index, function | software ID, code].
//
// Tested on an MX Keys Mini over Bluetooth with Logi Options+ running
// (Tools/BacklightProbe.swift), which showed two things this code is built on:
//   - Reports arrive on a private dispatch queue, the way async-hid (OpenLogi's
//     HID layer on macOS) does it, with a separate IOHIDDevice opened from the
//     registry ID rather than the manager's own.
//   - The keyboard's HID++ channel goes quiet about 1.5 s after the Mac last
//     sent it something. Asking for the level once a second keeps every change
//     notification coming, and the answer catches any that slip through. So
//     Brim asks once a second (four times a second for a moment after a change), and only while you're using the Mac.

/// One reading of the keyboard backlight.
struct BacklightReading: Equatable {
    enum Status: UInt8 {
        case offBySoftware = 0
        case offLowBattery = 1
        case automatic = 2           // the light sensor sets the level
        case automaticSaturated = 3  // the room is bright enough: off for now
        case temporaryManual = 4     // set with the backlight keys
        case permanentManual = 5     // set by software (Options+, Brim)
    }

    /// Selectable levels, 0 (off) included. The MX Keys Mini has 8.
    var levels: Int
    var level: Int
    var status: Status

    /// From getBacklightInfo's reply or a backlightInfoEvent.
    init?(_ bytes: ArraySlice<UInt8>) {
        guard bytes.count >= 3 else { return nil }
        let b = Array(bytes)
        levels = Int(b[0])
        level = Int(b[1])
        status = Status(rawValue: b[2]) ?? .permanentManual
        guard levels > 1 else { return nil }
    }

    var isAuto: Bool { status == .automatic || status == .automaticSaturated }
    var isOff: Bool {
        status == .offBySoftware || status == .offLowBattery || status == .automaticSaturated
            || (!isAuto && level == 0)
    }

    /// Steps above off (the bar is full at the top one).
    var dotCount: Int { max(levels - 1, 1) }
    var litDots: Int { isOff ? 0 : min(level, dotCount) }   // steps lit

    var label: String {
        if status == .offLowBattery { return "Off \u{00B7} Battery Low" }
        if isAuto { return "Auto" }
        if isOff { return "Off" }
        return "Level \(level)"
    }

    /// Which of the icon's four looks: off, low, middle (from halfway up) or
    /// the top level. The volume icon follows the same steps.
    var tier: LevelTier {
        if isOff { return .off }
        if level >= dotCount { return .maximum }
        if level >= (dotCount + 1) / 2 { return .middle }
        return .low
    }

    /// How full the banner's bar is.
    var fraction: Double { Double(litDots) / Double(dotCount) }

    /// Worth a banner? Changes you made, not ones the light sensor made.
    func announces(after previous: BacklightReading) -> Bool {
        if self == previous { return false }
        if isAuto && previous.isAuto { return false }
        return true
    }
}

extension NotchAlert {
    /// The backlight banner. One live banner: pressing the keys again while
    /// it's up updates it in place instead of queuing another.
    static func backlightBanner(_ reading: BacklightReading) -> NotchAlert {
        let on = !reading.isOff
        let symbol = Self.firstSymbol(on ? ["light.max", "sun.max.fill"] : ["light.min", "sun.min.fill"])
        return NotchAlert(symbol: symbol, tint: on ? .white : .gray,
                          title: "Keyboard Backlight", subtitle: reading.label,
                          duration: 2, backlight: reading, liveKey: "keyboardBacklight")
    }

    private static func firstSymbol(_ names: [String]) -> String {
        names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "keyboard"
    }
}

// MARK: - Battery

/// A Logitech device's battery, from HID++ Unified Battery (0x1004) or the
/// older Battery Status (0x1000), checked in OpenLogi
/// (feature/unified_battery.rs, battery_status.rs) and Solaar (hidpp20.py).
/// Both put the percentage first and the charging status third, in their
/// reply and in their change event (event 0):
///   0x1004 function 1 getStatus -> [percent, level flags, status, ...]
///   0x1000 function 0 getBatteryLevelStatus -> [percent, next level, status]
struct LogiBattery: Equatable {
    var percent: Int
    /// 0 discharging, 1 charging, 2 nearly full, 3 full, 4 charging slowly,
    /// 5-7 errors.
    var status: UInt8

    init?(_ bytes: ArraySlice<UInt8>) {
        guard bytes.count >= 3 else { return nil }
        let b = Array(bytes)
        percent = Int(b[0])
        status = b[2]
        guard percent <= 100 else { return nil }
    }

    var isCharging: Bool { status == 1 || status == 2 || status == 4 }
    var isFull: Bool { status == 3 }
    var onBattery: Bool { status == 0 }
}

extension NotchAlert {
    /// Same look as Brim's other accessory battery banners: the battery ring.
    @MainActor
    static func logitechBattery(_ battery: LogiBattery, device name: String, low: Bool) -> NotchAlert {
        let symbol = BluetoothMonitor.symbol(for: name)
        if low {
            return NotchAlert(symbol: symbol, tint: .red, title: name,
                              subtitle: "Battery Low \u{00B7} \(battery.percent)%",
                              duration: 6, battery: DeviceBattery(single: battery.percent))
        }
        if battery.isFull {
            return NotchAlert(symbol: symbol, tint: .green, title: name, subtitle: "Fully Charged",
                              battery: DeviceBattery(single: 100))
        }
        return NotchAlert(symbol: symbol, tint: .green, title: name,
                          subtitle: "Charging \u{00B7} \(battery.percent)%",
                          battery: DeviceBattery(single: battery.percent, singleCharging: true))
    }
}

// MARK: - Monitor

/// Follows the Logitech devices paired with this Mac over Bluetooth (MX Keys,
/// MX Master, MX Dialpad...): the keyboard's backlight, and every device's
/// battery. Follows each one as it disconnects, sleeps, switches to another
/// computer and comes back.
@MainActor
@Observable
final class LogitechMonitor {
    enum State: Equatable {
        case off
        /// Brim needs Input Monitoring to talk to the devices.
        case needsAccess
        case searching
        /// The names of the devices Brim is following.
        case connected([String])
    }

    private(set) var state: State = .off
    private(set) var backlight: BacklightReading?

    /// A backlight change you made: show the banner.
    @ObservationIgnored var onBacklightChange: (@MainActor (BacklightReading) -> Void)?
    /// Battery low, charging, fully charged.
    @ObservationIgnored var onBatteryAlert: (@MainActor (NotchAlert) -> Void)?

    /// Where a device reports its battery, and which function reads it.
    private struct BatteryFeature {
        let index: UInt8
        let readFunction: UInt8
    }

    private final class Device {
        let id: UInt64
        let channel: HIDPPDevice
        let name: String
        let backlightIndex: UInt8?
        let battery: BatteryFeature?
        var lastBattery: LogiBattery?
        var lastBatteryRead = Date()
        var batteryReadInFlight = false

        init(id: UInt64, channel: HIDPPDevice, name: String, backlightIndex: UInt8?, battery: BatteryFeature?) {
            self.id = id
            self.channel = channel
            self.name = name
            self.backlightIndex = backlightIndex
            self.battery = battery
        }
    }

    @ObservationIgnored private var manager: IOHIDManager?
    private let managerQueue = DispatchQueue(label: "app.brim.logitech.manager")
    /// Requests block until the device answers, so they run here, one at a time.
    private let work = DispatchQueue(label: "app.brim.logitech.requests")
    @ObservationIgnored private var devices: [UInt64: Device] = [:]
    /// The keyboard whose backlight Brim follows.
    @ObservationIgnored private var backlightDeviceID: UInt64?
    @ObservationIgnored private var probing: Set<UInt64> = []
    /// Devices with neither a backlight nor a battery to follow.
    @ObservationIgnored private var nothingToFollow: Set<UInt64> = []
    /// Devices seen before Input Monitoring was allowed.
    @ObservationIgnored private var waitingForAccess: Set<UInt64> = []
    @ObservationIgnored private var waitingForQuiet = Set<UInt64>()
    @ObservationIgnored private var watchingQuiet = false
    @ObservationIgnored private var askedForAccess = false
    /// Failed attempts per device, for retrying a few times.
    @ObservationIgnored private var attempts: [UInt64: Int] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var readInFlight = false
    @ObservationIgnored private var lastRead = Date.distantPast
    /// Right after a change, check more often, so a quick run of presses
    /// never waits on the once-a-second check.
    @ObservationIgnored private var fastUntil = Date.distantPast
    /// The newest report applied (see HIDPPDevice.sequence).
    @ObservationIgnored private var lastSequence: UInt64 = 0
    /// The lowest low-battery step announced per device name (20, 10, 5).
    /// By name, so a device that sleeps and reconnects isn't warned again.
    @ObservationIgnored private var warnedSteps: [String: Int] = [:]

    /// See the note at the top of the file.
    static let checkInterval: TimeInterval = 1
    static let fastInterval: TimeInterval = 0.25
    static let fastFor: TimeInterval = 2
    /// No mouse or keyboard input for this long: stop asking until you're back.
    static let idleAfter: TimeInterval = 120
    private static let batterySteps = [20, 10, 5]
    /// How often each battery is read. The keyboard's channel stays awake
    /// (the backlight check), so its battery events arrive and this is only
    /// a backstop; other devices' channels go quiet, so they're read every
    /// minute, which also catches plugging in and unplugging within a minute.
    private static let batteryInterval: TimeInterval = 60
    private static let batteryIntervalWithEvents: TimeInterval = 5 * 60

    static let inputMonitoringSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    func start() {
        guard state == .off else { return }
        state = .searching
        startManager()
        if !watchingQuiet {
            watchingQuiet = true
            QuietState.shared.whenActiveAgain { [weak self] in
                guard let self, self.state != .off else { return }
                let waiting = self.waitingForQuiet
                self.waitingForQuiet.removeAll()
                for id in waiting { self.reprobe(id) }
            }
        }
        let t = Timer(timeInterval: Self.fastInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let manager {
            // Kept alive until the cancel completes, then let go.
            var keepAlive: IOHIDManager? = manager
            IOHIDManagerSetCancelHandler(manager) {
                if keepAlive != nil { keepAlive = nil }
            }
            IOHIDManagerCancel(manager)
        }
        manager = nil
        devices.values.forEach { $0.channel.close() }
        devices.removeAll()
        backlightDeviceID = nil
        backlight = nil
        probing.removeAll()
        waitingForAccess.removeAll()
        waitingForQuiet.removeAll()
        state = .off
    }

    /// Whether Brim follows this device's battery itself, so the general
    /// accessory battery check can leave it alone (no double warnings).
    func handlesBattery(of name: String) -> Bool {
        devices.values.contains { $0.name == name && $0.battery != nil }
    }

    private func updateState() {
        guard state != .off, state != .needsAccess else { return }
        let names = devices.values.map(\.name).sorted()
        state = names.isEmpty ? .searching : .connected(names)
    }

    // MARK: Finding devices

    /// Watching for devices needs no permission; opening one does. So Brim
    /// asks for Input Monitoring only once a Logitech device shows up.
    private func startManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context, let candidate = Candidate(device) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Unmanaged<LogitechMonitor>.fromOpaque(context).takeUnretainedValue().found(candidate)
                }
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context, let id = Candidate.registryID(of: device) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Unmanaged<LogitechMonitor>.fromOpaque(context).takeUnretainedValue().lost(id)
                }
            }
        }, context)
        IOHIDManagerSetDispatchQueue(manager, managerQueue)
        IOHIDManagerActivate(manager)
        self.manager = manager
    }

    /// A Logitech device paired straight over Bluetooth LE: it has the HID++
    /// collection (vendor page 0xFF43, usage 0x0202).
    private struct Candidate: Sendable {
        let id: UInt64
        let name: String

        init?(_ device: IOHIDDevice) {
            var pairs: [(page: Int, usage: Int)] = []
            if let list = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] {
                for p in list {
                    if let page = p[kIOHIDDeviceUsagePageKey] as? Int, let usage = p[kIOHIDDeviceUsageKey] as? Int {
                        pairs.append((page, usage))
                    }
                }
            }
            guard pairs.contains(where: { $0.page == 0xFF43 && $0.usage == 0x0202 }),
                  let id = Self.registryID(of: device) else { return nil }
            self.id = id
            name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech Device"
        }

        static func registryID(of device: IOHIDDevice) -> UInt64? {
            var id: UInt64 = 0
            let service = IOHIDDeviceGetService(device)
            guard service != 0, IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return nil }
            return id
        }
    }

    private func found(_ candidate: Candidate) {
        guard state != .off, devices[candidate.id] == nil,
              !probing.contains(candidate.id), !nothingToFollow.contains(candidate.id) else { return }
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            break
        case kIOHIDAccessTypeDenied:
            waitingForAccess.insert(candidate.id)
            state = .needsAccess
            return
        default:
            waitingForAccess.insert(candidate.id)
            state = .needsAccess
            if !askedForAccess {
                askedForAccess = true
                work.async { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
            }
            return
        }
        // Locked or asleep: devices reconnecting as the Mac wakes for a
        // moment are left alone until you're back, so Brim never talks to
        // them while the Mac is meant to rest.
        if QuietState.shared.isQuiet {
            waitingForQuiet.insert(candidate.id)
            return
        }
        probing.insert(candidate.id)
        appLog.info("Logitech: trying \(candidate.name, privacy: .public)")
        // The monitor lives as long as Brim, so holding on to it here is fine;
        // the channel lets go of its closures when it closes.
        work.async { [self] in
            let result = Self.connect(candidate, onEvent: { [self] bytes, sequence in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.event(bytes, sequence: sequence, from: candidate.id) }
                }
            }, onRemoved: { [self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.lost(candidate.id) } }
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.connected(candidate, result) }
            }
        }
    }

    private enum ConnectResult {
        case ready(Device, BacklightReading?, LogiBattery?)
        case nothingToFollow
        case failed
    }

    /// Opens the device and looks up its backlight and battery. Runs on `work`.
    nonisolated private static func connect(_ candidate: Candidate,
                                            onEvent: @escaping ([UInt8], UInt64) -> Void,
                                            onRemoved: @escaping () -> Void) -> ConnectResult {
        guard let channel = HIDPPDevice(registryID: candidate.id),
              channel.open(onEvent: onEvent, onRemoved: onRemoved) else { return .failed }
        func feature(_ hi: UInt8, _ lo: UInt8) -> UInt8?? {
            guard let reply = channel.call(feature: 0, function: 0, [hi, lo]) else { return nil }   // no answer
            return .some(reply[0] == 0 ? nil : reply[0])                                             // absent / index
        }
        guard let backlightLookup = feature(0x19, 0x82) else { channel.close(); return .failed }
        var backlightIndex = backlightLookup
        var backlight: BacklightReading?
        if let index = backlightIndex {
            backlight = channel.call(feature: index, function: 2).flatMap { BacklightReading($0[...]) }
            if backlight == nil { backlightIndex = nil }
        }
        var battery: BatteryFeature?
        if let index = feature(0x10, 0x04) ?? nil {
            battery = BatteryFeature(index: index, readFunction: 1)
        } else if let index = feature(0x10, 0x00) ?? nil {
            battery = BatteryFeature(index: index, readFunction: 0)
        }
        guard backlightIndex != nil || battery != nil else {
            channel.close()
            return .nothingToFollow
        }
        let firstBattery = battery.flatMap { b in
            channel.call(feature: b.index, function: b.readFunction).flatMap { LogiBattery($0[...]) }
        }
        let device = Device(id: candidate.id, channel: channel, name: candidate.name,
                            backlightIndex: backlightIndex, battery: battery)
        return .ready(device, backlight, firstBattery)
    }

    private func connected(_ candidate: Candidate, _ result: ConnectResult) {
        probing.remove(candidate.id)
        switch result {
        case .ready(let device, let firstBacklight, let firstBattery):
            guard state != .off, devices[candidate.id] == nil else { device.channel.close(); return }
            devices[candidate.id] = device
            attempts[candidate.id] = nil
            if let firstBacklight, backlightDeviceID == nil {
                backlightDeviceID = candidate.id
                backlight = firstBacklight     // where it stands now; no banner for that
                lastSequence = 0
            }
            if let firstBattery { applyBattery(firstBattery, to: device) }   // warns if it's already low
            updateState()
            Diag.event("Logitech: \(candidate.name) connected")
            appLog.info("Logitech: \(candidate.name, privacy: .public) connected (backlight: \(device.backlightIndex != nil), battery: \(device.battery != nil))")
        case .nothingToFollow:
            nothingToFollow.insert(candidate.id)
        case .failed:
            // Often a device still waking up. It stays matched, so no new
            // match comes; try again a few times.
            let tries = (attempts[candidate.id] ?? 0) + 1
            attempts[candidate.id] = tries
            appLog.info("Logitech: couldn't reach \(candidate.name, privacy: .public) (try \(tries))")
            guard tries < 5 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.devices[candidate.id] == nil, self.state != .off else { return }
                    self.reprobe(candidate.id)
                }
            }
        }
    }

    private func lost(_ id: UInt64) {
        waitingForAccess.remove(id)
        nothingToFollow.remove(id)
        attempts[id] = nil
        guard let device = devices.removeValue(forKey: id) else { return }
        device.channel.close()
        if backlightDeviceID == id {
            backlightDeviceID = nil
            backlight = nil
        }
        updateState()
        Diag.event("Logitech: \(device.name) gone")
        appLog.info("Logitech: \(device.name, privacy: .public) gone (disconnected, asleep or on another computer)")
    }

    /// Looks again at a device that's already attached (after Input
    /// Monitoring was allowed, or after a failed first try).
    private func reprobe(_ id: UInt64) {
        guard let manager, let all = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for device in all {
            if let candidate = Candidate(device), candidate.id == id { found(candidate) }
        }
    }

    // MARK: Following

    private func tick() {
        if state == .needsAccess {
            guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
            state = .searching
            // Try the devices that showed up while waiting.
            for id in waitingForAccess { reprobe(id) }
            waitingForAccess.removeAll()
            return
        }
        // Nothing while the Mac is locked or dark: Bluetooth traffic then has
        // no one to show a banner to, and keeps the Mac from resting.
        guard !devices.isEmpty, !QuietState.shared.isQuiet, Self.isUserActive else { return }
        Diag.count("logitech.tick")
        for device in devices.values { readBatteryIfDue(device) }
        readBacklightIfDue()
    }

    private func readBacklightIfDue() {
        guard let id = backlightDeviceID, let device = devices[id], let index = device.backlightIndex,
              !readInFlight else { return }
        let now = Date()
        let interval = now < fastUntil ? Self.fastInterval : Self.checkInterval
        guard now.timeIntervalSince(lastRead) >= interval - 0.01 else { return }
        readInFlight = true
        lastRead = now
        let channel = device.channel
        work.async { [self] in
            Diag.count("logitech.request")
            let info = channel.stampedCall(feature: index, function: 2, timeout: 1)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.readInFlight = false
                    // Still the same keyboard (it may have gone meanwhile).
                    guard self.backlightDeviceID == id, self.devices[id]?.channel === channel,
                          let info, let reading = BacklightReading(info.params[...]) else { return }
                    self.applyBacklight(reading, sequence: info.sequence)
                }
            }
        }
    }

    private func readBatteryIfDue(_ device: Device) {
        guard let battery = device.battery, !device.batteryReadInFlight else { return }
        let interval = device.id == backlightDeviceID ? Self.batteryIntervalWithEvents : Self.batteryInterval
        guard Date().timeIntervalSince(device.lastBatteryRead) >= interval else { return }
        device.batteryReadInFlight = true
        device.lastBatteryRead = Date()
        // Only Sendable values cross queues: the channel and the device's ID.
        let channel = device.channel, id = device.id
        work.async { [self] in
            Diag.count("logitech.request")
            let status = channel.call(feature: battery.index, function: battery.readFunction, timeout: 1)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Still the same connection (it may have gone meanwhile).
                    guard let device = self.devices[id], device.channel === channel else { return }
                    device.batteryReadInFlight = false
                    guard let status, let reading = LogiBattery(status[...]) else { return }
                    self.applyBattery(reading, to: device)
                }
            }
        }
    }

    /// A device's own change event (event 0): the backlight's level, or the
    /// battery. The new value is in the event, so the banner follows straight
    /// away while you hold the key.
    private func event(_ bytes: [UInt8], sequence: UInt64, from id: UInt64) {
        Diag.count("logitech.event")
        guard let device = devices[id], bytes.count >= 8, bytes[3] >> 4 == 0 else { return }
        if id == backlightDeviceID, bytes[2] == device.backlightIndex, let reading = BacklightReading(bytes[4...]) {
            applyBacklight(reading, sequence: sequence)
        } else if bytes[2] == device.battery?.index, let battery = LogiBattery(bytes[4...]) {
            applyBattery(battery, to: device)
        }
    }

    /// Readings are applied in the order the keyboard sent them: an answer
    /// to a check sent just before a press can reach the main thread after
    /// the press's own event, and would otherwise pull the bar back a step.
    private func applyBacklight(_ new: BacklightReading, sequence: UInt64) {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        let previous = backlight
        backlight = new
        guard let previous, new != previous else { return }
        fastUntil = Date().addingTimeInterval(Self.fastFor)
        guard new.announces(after: previous) else { return }
        onBacklightChange?(new)
    }

    /// Battery banners: low (20%, 10%, 5%, once each per discharge), started
    /// charging, fully charged.
    private func applyBattery(_ new: LogiBattery, to device: Device) {
        let previous = device.lastBattery
        device.lastBattery = new
        let name = device.name
        if new.isCharging || new.isFull || new.percent > 30 { warnedSteps[name] = nil }
        if let previous {
            if (new.isCharging && !previous.isCharging && !previous.isFull) || (new.isFull && !previous.isFull) {
                onBatteryAlert?(.logitechBattery(new, device: name, low: false))
                return
            }
        }
        guard new.onBattery,
              let step = Self.batterySteps.last(where: { new.percent <= $0 }),
              warnedSteps[name].map({ step < $0 }) ?? true else { return }
        warnedSteps[name] = step
        onBatteryAlert?(.logitechBattery(new, device: name, low: true))
    }

    /// Someone is at the Mac: any key, click, scroll or mouse movement recently.
    private static var isUserActive: Bool {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown,
                                    .rightMouseDown, .scrollWheel, .leftMouseDragged]
        let idle = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
        return idle < idleAfter
    }
}

// MARK: - HID++ channel

/// One Logitech device's HID++ 2.0 channel over Bluetooth LE.
///
/// Its own IOHIDDevice (not the manager's), with reports delivered on a
/// private serial queue: the setup async-hid uses on macOS. Requests are
/// synchronous and must not be made on the main thread.
final class HIDPPDevice: @unchecked Sendable {
    let registryID: UInt64
    private let device: IOHIDDevice
    private let io = DispatchQueue(label: "app.brim.hidpp.io")
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int

    // Touched only on `io`.
    private var pending: (feature: UInt8, function: UInt8)?
    private var reply: [UInt8]?
    private var replySequence: UInt64 = 0
    /// Counts reports in the order they arrive, so a reply and an event that
    /// race each other to the main thread can be put back in order.
    private var sequence: UInt64 = 0
    private var onEvent: (([UInt8], UInt64) -> Void)?
    private var onRemoved: (() -> Void)?
    private var isOpen = false
    private let replied = DispatchSemaphore(value: 0)

    /// Ours, so replies to Logi Options+ (which shares the keyboard) are told
    /// apart. Events from the keyboard itself carry 0.
    static let softwareID: UInt8 = 0x0A
    static let reportLength = 20

    init?(registryID: UInt64) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return nil }
        self.registryID = registryID
        self.device = device
        let maxInput = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        bufferSize = max(maxInput, 64)
        buffer = .allocate(capacity: bufferSize)
    }

    deinit {
        buffer.deallocate()
    }

    func open(onEvent: @escaping ([UInt8], UInt64) -> Void, onRemoved: @escaping () -> Void) -> Bool {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            // macOS refuses silently without Input Monitoring; 0xE00002C5 is
            // another app holding the device exclusively.
            appLog.error("Backlight: opening failed, 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
            return false
        }
        self.onEvent = onEvent
        self.onRemoved = onRemoved
        isOpen = true
        IOHIDDeviceSetDispatchQueue(device, io)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let me = Unmanaged<HIDPPDevice>.fromOpaque(context).takeUnretainedValue()
            // Only HID++ reports are looked at. Typing arrives here too (it's
            // one Bluetooth device) and is dropped unread.
            let id = UInt8(truncatingIfNeeded: reportID)
            guard id == 0x11 || id == 0x10 else { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            if bytes.first != id { bytes.insert(id, at: 0) }
            me.received(bytes)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<HIDPPDevice>.fromOpaque(context).takeUnretainedValue().onRemoved?()
        }, context)
        IOHIDDeviceActivate(device)
        return true
    }

    /// Stops delivery, then closes the device (the order async-hid uses).
    /// Until the cancel handler runs, IOKit may still call the callbacks that
    /// point at this object, so the handler holds on to it until then.
    func close() {
        let wasOpen: Bool = io.sync {
            defer { isOpen = false; onEvent = nil; onRemoved = nil }
            return isOpen
        }
        guard wasOpen else { return }
        var keepAlive: HIDPPDevice? = self
        IOHIDDeviceSetCancelHandler(device) {
            if let me = keepAlive { IOHIDDeviceClose(me.device, IOOptionBits(kIOHIDOptionsTypeNone)) }
            keepAlive = nil
        }
        IOHIDDeviceCancel(device)
    }

    private func received(_ bytes: [UInt8]) {
        guard bytes.count >= 4 else { return }
        sequence &+= 1
        if let p = pending {
            let call = (p.function << 4) | Self.softwareID
            let isReply = bytes[2] == p.feature && bytes[3] == call
            let isError = bytes[2] == 0xFF && bytes.count >= 6 && bytes[3] == p.feature && bytes[4] == call
            if isReply || isError {
                pending = nil
                reply = bytes
                replySequence = sequence
                replied.signal()
                return
            }
        }
        let swid = bytes[2] == 0xFF ? (bytes.count > 4 ? bytes[4] & 0x0F : 0xFF) : bytes[3] & 0x0F
        if swid == 0 { onEvent?(bytes, sequence) }
    }

    /// Sends a long HID++ 2.0 request and waits for its reply. Returns the 16
    /// parameter bytes, or nil on an error or no answer.
    func call(feature: UInt8, function: UInt8, _ params: [UInt8] = [], timeout: TimeInterval = 2) -> [UInt8]? {
        stampedCall(feature: feature, function: function, params, timeout: timeout)?.params
    }

    /// The same, plus where the reply came in the order of reports.
    func stampedCall(feature: UInt8, function: UInt8, _ params: [UInt8] = [],
                     timeout: TimeInterval = 2) -> (params: [UInt8], sequence: UInt64)? {
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        report[0] = 0x11
        report[1] = 0xFF
        report[2] = feature
        report[3] = (function << 4) | Self.softwareID
        for (i, b) in params.prefix(16).enumerated() { report[4 + i] = b }
        let ready: Bool = io.sync {
            while replied.wait(timeout: .now()) == .success {}   // a late answer to an earlier request
            pending = (feature, function)
            reply = nil
            return isOpen
        }
        guard ready else { return nil }
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0x11), report, report.count)
        guard result == kIOReturnSuccess else {
            io.sync { pending = nil }
            return nil
        }
        _ = replied.wait(timeout: .now() + timeout)
        let answer: (bytes: [UInt8], sequence: UInt64)? = io.sync {
            pending = nil
            guard let reply else { return nil }
            return (reply, replySequence)
        }
        guard let answer, answer.bytes.count >= 5, answer.bytes[2] != 0xFF else { return nil }
        let r = answer.bytes
        return (Array(r[4..<min(r.count, Self.reportLength)]), answer.sequence)
    }
}

// MARK: - Banner content

/// The banner's icon: rays over a baseline, in four lengths: dots when off,
/// short from level 1, longer from level 4, longest at level 7.
/// Off, the rays shrink to dots and the whole icon turns gray (the banner's
/// tint). Drawn rather than an SF Symbol (those come in only two sizes, min
/// and max), so the rays can stretch from one look to the next.
struct BacklightGlyph: View {
    let reading: BacklightReading
    let size: CGFloat

    /// Ray length as a fraction of the icon's width.
    /// Four looks, like the volume icon: off (dots), low (level 1 and up),
    /// middle (from halfway, level 4 of 7) and the top level.
    private var rayLength: CGFloat {
        switch reading.tier {
        case .off: return 0
        case .low: return 0.07
        case .middle: return 0.115
        case .maximum: return 0.16
        }
    }

    var body: some View {
        ZStack {
            BacklightBaseShape()
                .fill()
            BacklightRaysShape(length: rayLength)
                .stroke(style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.18, dampingFraction: 0.92), value: rayLength)
    }
}

/// The baseline the rays rise from, like the keyboard brightness keys' icon.
private struct BacklightBaseShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let center = CGPoint(x: rect.midX, y: rect.minY + w * 0.62)
        var path = Path()
        path.addRoundedRect(in: CGRect(x: rect.minX + w * 0.2, y: center.y + w * 0.06, width: w * 0.6, height: w * 0.075),
                            cornerSize: CGSize(width: w * 0.0375, height: w * 0.0375))
        return path
    }
}

/// Five rays fanning out above the baseline. At length 0 the round caps
/// leave a dot each, which is the off look.
private struct BacklightRaysShape: Shape {
    var length: CGFloat

    var animatableData: CGFloat {
        get { length }
        set { length = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let center = CGPoint(x: rect.midX, y: rect.minY + w * 0.62)
        let start = w * 0.22
        for degrees in [180.0, 135.0, 90.0, 45.0, 0.0] {
            let angle = degrees * .pi / 180
            let dx = CGFloat(cos(angle)), dy = -CGFloat(sin(angle))   // up is negative y
            path.move(to: CGPoint(x: center.x + dx * start, y: center.y + dy * start))
            path.addLine(to: CGPoint(x: center.x + dx * (start + w * length),
                                     y: center.y + dy * (start + w * length)))
        }
        return path
    }
}

import AppKit
import SwiftUI
import IOKit.ps
import IOBluetooth
import CoreBluetooth
import Observation

/// One notification shown in the notch. A value type: copies are independent,
/// identity comes from `id`.
struct NotchAlert: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String? = nil
    var body: String? = nil
    var image: NSImage? = nil      // album artwork for song changes
    var appIcon: NSImage? = nil    // mirrored notifications: the sending app's icon
    var appName: String? = nil
    var bundleID: String? = nil
    var duration: TimeInterval = 4
    var date = Date()
    /// Device banners: battery levels shown as rings (AirPods, like iPhone).
    var battery: DeviceBattery? = nil
    /// Finished downloads: clicking the notification shows the file in Finder.
    var fileURL: URL? = nil
    /// Keyboard backlight banner: the level bar.
    var backlight: BacklightReading? = nil
    /// Volume banner: the level bar and speaker icon.
    var volume: VolumeReading? = nil
    /// Monitor brightness banner: the level bar (0...1).
    var brightness: Double? = nil
    /// Live banners (the keyboard backlight) update in place while they're up:
    /// a new one with the same key replaces the content instead of queuing.
    var liveKey: String? = nil
    /// Goes up each time a live banner changes in place. SwiftUI compares
    /// views by their Equatable values, so without it an updated banner (same
    /// id) looks unchanged and isn't redrawn.
    var revision = 0
    /// Clicking it does this instead of opening an app (and then it goes).
    var action: AlertAction? = nil

    static func == (lhs: NotchAlert, rhs: NotchAlert) -> Bool { lhs.id == rhs.id && lhs.revision == rhs.revision }

    /// The line shown under the title in compact rows.
    var detail: String? { body ?? subtitle ?? appName }
}

/// Something Brim does when you click a notification.
enum AlertAction: Equatable {
    /// "Break Over": start the next Focus round.
    case startFocus
}

/// Queues notifications, shows them one at a time, and keeps a short history
/// for the expanded view (newest first).
@MainActor
@Observable
final class AlertCenter {
    private(set) var current: NotchAlert?
    private(set) var history: [NotchAlert] = []

    @ObservationIgnored private var pending: [NotchAlert] = []
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var shownAt = Date()
    /// Runs a notification's action (wired in App).
    @ObservationIgnored var onAction: (@MainActor (AlertAction) -> Void)?

    /// When more are waiting, each banner stays only this long, so a burst of
    /// messages doesn't pile up seconds behind.
    static let minimumVisible: TimeInterval = 1.5

    static let historyLimit = 30

    /// Banners wait (the teleprompter is on): they go to the list, and the
    /// last few show once it's over.
    @ObservationIgnored private var holding = false

    func holdBanners(_ hold: Bool) {
        guard hold != holding else { return }
        holding = hold
        if hold {
            dismissTask?.cancel()
            current = nil
        } else if current == nil, !pending.isEmpty {
            // Only the latest few: the rest are in the list.
            pending = Array(pending.suffix(3))
            show(pending.removeFirst())
        }
    }

    /// Shows a banner, and (by default) keeps it in history.
    func post(_ alert: NotchAlert, remember: Bool = true) {
        Diag.count("alerts.post")
        if remember { self.remember(alert) }
        if holding {
            // Volume, brightness and the like don't matter later.
            if alert.liveKey == nil { pending.append(alert) }
            return
        }
        if current == nil {
            show(alert)
        } else {
            pending.append(alert)
            // Cut the one on screen short (it stays in the list).
            let visible = Date().timeIntervalSince(shownAt)
            scheduleAdvance(after: max(0, Self.minimumVisible - visible))
        }
    }

    /// A banner that follows something as it changes, like the keyboard
    /// backlight while you keep pressing its keys: if one with the same key is
    /// on screen it changes in place and its timer starts over. Never kept in
    /// the list.
    func postLive(_ alert: NotchAlert) {
        Diag.count("alerts.postLive")
        guard let key = alert.liveKey else { post(alert, remember: false); return }
        guard !holding else { return }
        if var shown = current, shown.liveKey == key {
            shown.symbol = alert.symbol
            shown.tint = alert.tint
            shown.title = alert.title
            shown.subtitle = alert.subtitle
            shown.body = alert.body
            shown.backlight = alert.backlight
            shown.volume = alert.volume
            shown.brightness = alert.brightness
            shown.date = alert.date
            shown.revision += 1
            withAnimation(.spring(response: 0.18, dampingFraction: 0.92)) { current = shown }
            shownAt = Date()
            scheduleAdvance(after: pending.isEmpty ? alert.duration : Self.minimumVisible)
            return
        }
        if let index = pending.firstIndex(where: { $0.liveKey == key }) {
            pending[index] = alert
            return
        }
        post(alert, remember: false)
    }

    /// A click on a banner: opens what it's about and sends it away. False
    /// for banners with nothing to open (volume, battery...).
    @discardableResult
    func openFromBanner(_ alert: NotchAlert) -> Bool {
        guard canOpen(alert) else { return false }
        open(alert)
        if current?.id == alert.id {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { dismissCurrent() }
        }
        return true
    }

    /// Whether clicking it leads somewhere: an action, a file, or an app
    /// that's actually on this Mac (helpers count as their main app).
    func canOpen(_ alert: NotchAlert) -> Bool {
        if alert.action != nil || alert.fileURL != nil { return true }
        guard let bundleID = alert.bundleID else { return false }
        let target = bundleID.lowercased().hasPrefix("web.") ? "com.apple.Safari" : bundleID
        return AppLocator.url(for: target) != nil
    }

    /// Sends the banner on screen away now (swiped up); it stays in the list.
    /// The next waiting one comes in.
    func dismissCurrent() {
        guard current != nil else { return }
        dismissTask?.cancel()
        advance()
    }

    /// Adds to history only, no banner.
    func remember(_ alert: NotchAlert) {
        let index = history.firstIndex { $0.date < alert.date } ?? history.endIndex
        history.insert(alert, at: index)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    /// Brings the app that sent a notification to the front, like clicking it in
    /// Notification Center.
    func open(_ alert: NotchAlert) {
        if let action = alert.action {
            onAction?(action)
            // Done with it: off the list, and off the screen if it's showing.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { dismiss(alert.id) }
            if current?.id == alert.id { scheduleAdvance(after: 0) }
            return
        }
        if let file = alert.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return
        }
        guard let bundleID = alert.bundleID else { return }
        let target = bundleID.lowercased().hasPrefix("web.") ? "com.apple.Safari" : bundleID
        guard let url = AppLocator.url(for: target) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }

    func clearHistory() {
        history.removeAll()
    }

    /// Clear, with motion: the top notifications slide away one after another,
    /// then the rest of the list fades out.
    func clearAllAnimated() {
        guard !history.isEmpty else { return }
        let first = history.prefix(6).map(\.id)
        Task { @MainActor [weak self] in
            for id in first {
                guard let self else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { self.dismiss(id) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self, !self.history.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.history.removeAll() }
        }
    }

    /// Takes one notification off Brim's list (macOS's Notification Center
    /// keeps its own copy).
    func dismiss(_ id: UUID) {
        history.removeAll { $0.id == id }
    }

    func dismiss(_ ids: [UUID]) {
        let set = Set(ids)
        history.removeAll { set.contains($0.id) }
    }

    private func show(_ alert: NotchAlert) {
        current = alert
        shownAt = Date()
        scheduleAdvance(after: pending.isEmpty ? alert.duration : Self.minimumVisible)
    }

    private func scheduleAdvance(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    private func advance() {
        if pending.isEmpty {
            current = nil
        } else {
            show(pending.removeFirst())
        }
    }
}

// MARK: - Battery / charger

@MainActor
final class PowerMonitor {
    private struct PowerState: Equatable {
        var onAC: Bool
        var level: Int
    }

    private let onAlert: @MainActor (NotchAlert) -> Void
    private var source: CFRunLoopSource?
    private var last: PowerState?

    init(onAlert: @escaping @MainActor (NotchAlert) -> Void) {
        self.onAlert = onAlert
    }

    func start() {
        // Desktop Macs (like a Mac mini) have no battery: nothing to watch.
        guard Self.read() != nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().update()
            }
        }
        guard let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
        update()
    }

    fileprivate func update() {
        guard let now = Self.read() else { return }
        defer { last = now }
        guard let before = last, before != now else { return }

        if now.onAC != before.onAC {
            if now.onAC {
                post("battery.100.bolt", .green, "Charging", "\(now.level)%")
            } else {
                post(Self.symbol(for: now.level), .white, "On battery", "\(now.level)%")
            }
        } else if !now.onAC {
            for threshold in [20, 10] where before.level > threshold && now.level <= threshold {
                post("battery.25", threshold == 10 ? .red : .orange, "Low battery", "\(now.level)% remaining")
                break
            }
        } else {
            // The charge alert (Settings > Devices): at the level you chose,
            // once each time it charges past it. 100 = fully charged.
            let target = Self.chargeAlertLevel
            if target > 0, now.level >= target, before.level < target {
                if target >= 100 {
                    post("battery.100", .green, "Fully charged", "100%")
                } else {
                    post("battery.100.bolt", .green, "Charged to \(now.level)%", "You can unplug")
                }
            }
        }
    }

    /// 0 = off; otherwise the percent that shows the banner (default 100).
    static var chargeAlertLevel: Int {
        UserDefaults.standard.object(forKey: "chargeAlertLevel") as? Int ?? 100
    }

    /// The Mac has a battery (a MacBook).
    static var hasBattery: Bool { read() != nil }

    private func post(_ symbol: String, _ tint: Color, _ title: String, _ subtitle: String) {
        onAlert(NotchAlert(symbol: symbol, tint: tint, title: title, subtitle: subtitle))
    }

    private static func symbol(for level: Int) -> String {
        switch level {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    private static func read() -> PowerState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        for ps in list as Array {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps as CFTypeRef)?
                    .takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = desc[kIOPSPowerSourceStateKey] as? String
            let level = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 0
            return PowerState(onAC: state == kIOPSACPowerValue, level: level)
        }
        return nil
    }
}

// MARK: - Bluetooth (headphones, AirPods, keyboards...)

/// Battery levels in percent; nil means unknown or not present.
struct DeviceBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// Single-battery devices (AirPods Max, Beats, keyboards).
    var single: Int?
    var leftCharging = false
    var rightCharging = false
    var caseCharging = false
    var singleCharging = false

    var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && single == nil }
}

/// Connection banners for Bluetooth devices, plus the iPhone-style AirPods
/// battery card: when AirPods connect, and when you open their case near the Mac.
@MainActor
final class BluetoothMonitor: NSObject, CBCentralManagerDelegate {
    private let onAlert: @MainActor (NotchAlert) -> Void
    private var connectNotification: IOBluetoothUserNotification?
    private var startedAt = Date()

    /// One entry per device address. macOS reports a connection once per
    /// Bluetooth profile (music, calls, controls...), so without this a single
    /// connect or disconnect would show up two or three times.
    private var connected: Set<String> = []
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var lastEvent: [String: Date] = [:]

    /// Connections (or disconnections) that arrived together, waiting to be
    /// merged into one banner.
    private var pendingConnects: [IOBluetoothDevice] = []
    private var pendingDisconnects: [IOBluetoothDevice] = []

    private var central: CBCentralManager?
    private var lastAirPodsCard = Date.distantPast

    init(onAlert: @escaping @MainActor (NotchAlert) -> Void) {
        self.onAlert = onAlert
        super.init()
    }

    func start() {
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(connected(_:device:)))
        // Listens for AirPods announcing themselves when their case opens.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Connect / disconnect

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? device.name ?? "unknown"
        if disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(forDisconnectNotification: self,
                                                               selector: #selector(disconnected(_:device:)))
        }
        guard connected.insert(address).inserted else { return }  // another profile of the same address
        // macOS reports already-connected devices right after registering; skip those.
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        enqueue(device, connected: true)
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? device.name ?? "unknown"
        note.unregister()
        disconnectNotifications[address] = nil
        guard connected.remove(address) != nil else { return }
        enqueue(device, connected: false)
    }

    /// AirPods show up as several Bluetooth connections a split second apart:
    /// one may have no name yet ("Bluetooth Device"), one the generic name
    /// ("AirPods Pro"), one yours ("Martin's AirPods Pro"). Everything that
    /// arrives within 1.5 s is collected, then announced once per device. The
    /// wait also gives AirPods time to report their battery.
    private func enqueue(_ device: IOBluetoothDevice, connected: Bool) {
        let wasEmpty = connected ? pendingConnects.isEmpty : pendingDisconnects.isEmpty
        if connected { pendingConnects.append(device) } else { pendingDisconnects.append(device) }
        guard wasEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.flush(connected: connected)
        }
    }

    private func flush(connected: Bool) {
        let devices = connected ? pendingConnects : pendingDisconnects
        if connected { pendingConnects.removeAll() } else { pendingDisconnects.removeAll() }
        announce(devices, connected: connected, canRetry: true)
    }

    /// Only devices macOS has identified get a banner. A connection that still
    /// has no name is checked once more a few seconds later; if it's still
    /// anonymous (often a nearby accessory or a background link from your own
    /// Apple devices), it's skipped.
    private func announce(_ devices: [IOBluetoothDevice], connected: Bool, canRetry: Bool) {
        // Group by product: "Martin's AirPods Pro" and "AirPods Pro" are one device.
        // Names are read now, after the wait, when macOS has resolved them.
        var groups: [String: [IOBluetoothDevice]] = [:]
        var order: [String] = []
        var unnamed: [IOBluetoothDevice] = []
        for device in devices {
            guard let name = device.name, !name.isEmpty else { unnamed.append(device); continue }
            let key = Self.productKey(name)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(device)
        }
        // A nameless connection next to a named one is the same device's other half.
        if order.isEmpty, !unnamed.isEmpty, canRetry {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.announce(unnamed, connected: connected, canRetry: false)
            }
        }

        for key in order {
            guard let group = groups[key],
                  let name = Self.bestName(group.compactMap(\.name)),
                  // Accessories only: your Watch, iPhone, iPad and Macs link up
                  // in the background all the time (Auto Unlock, Handoff, a
                  // notification arriving on the Watch), which isn't news.
                  Self.isAccessory(name: name, device: group.first),
                  isFresh(key, connected ? "connect" : "disconnect") else { continue }
            let battery = group.lazy.compactMap { Self.battery(of: $0) }.first
            if !connected {
                onAlert(NotchAlert(symbol: Self.symbol(for: name, device: group.first), tint: .gray,
                                   title: name, subtitle: "Disconnected"))
            } else if Self.isAirPods(name) {
                lastAirPodsCard = Date()
                onAlert(Self.airPodsAlert(name: name, battery: battery, status: "Connected"))
            } else {
                onAlert(NotchAlert(symbol: Self.symbol(for: name, device: group.first), tint: .blue,
                                   title: name, subtitle: "Connected", battery: battery))
            }
        }
    }

    /// "Martin's AirPods Pro" and "AirPods Pro" both become "airpods pro".
    private static func productKey(_ name: String) -> String {
        var key = name.lowercased()
        for apostrophe in ["'s ", "\u{2019}s "] {
            if let range = key.range(of: apostrophe) { key = String(key[range.upperBound...]) }
        }
        return key.trimmingCharacters(in: .whitespaces)
    }

    /// Prefer the personal name ("Martin's AirPods Pro"), then the longest.
    private static func bestName(_ names: [String]) -> String? {
        names.max { a, b in
            let aPersonal = a.contains("'s ") || a.contains("\u{2019}s ")
            let bPersonal = b.contains("'s ") || b.contains("\u{2019}s ")
            if aPersonal != bPersonal { return !aPersonal }
            return a.count < b.count
        }
    }

    /// Ignores a repeat of the same event for the same device within 10 seconds,
    /// in case its connections straddle two groups.
    private func isFresh(_ key: String, _ event: String) -> Bool {
        let id = key + "|" + event
        defer { lastEvent[id] = Date() }
        return Date().timeIntervalSince(lastEvent[id] ?? .distantPast) > 10
    }

    // MARK: Battery

    /// macOS keeps per-part battery levels on the Bluetooth device as hidden
    /// properties. Each is checked before reading, so a future macOS that renames
    /// them just shows no battery instead of crashing.
    private static func battery(of device: IOBluetoothDevice) -> DeviceBattery? {
        func read(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = device.value(forKey: key) as? NSNumber,
                  value.intValue > 0, value.intValue <= 100 else { return nil }
            return value.intValue
        }
        let battery = DeviceBattery(left: read("batteryPercentLeft"),
                                    right: read("batteryPercentRight"),
                                    caseLevel: read("batteryPercentCase"),
                                    single: read("batteryPercentSingle") ?? read("batteryPercentCombined"))
        return battery.isEmpty ? nil : battery
    }

    private static func airPodsAlert(name: String, battery: DeviceBattery?, status: String) -> NotchAlert {
        NotchAlert(symbol: symbol(for: name), tint: .white, title: name, subtitle: status,
                   duration: 5, battery: battery)
    }

    // MARK: Case opened nearby (proximity advertisements)

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let reading = Self.decodeProximity(data) else { return }
        let strength = RSSI.intValue
        MainActor.assumeIsolated { self.caseNearby(reading, rssi: strength) }
    }

    private func caseNearby(_ battery: DeviceBattery, rssi: Int) {
        // Only AirPods right next to the Mac (not someone else's across the
        // room), only if this Mac has AirPods paired, and at most once every
        // few minutes: the case broadcasts the whole time its lid is open.
        guard rssi > -52, rssi < 0,
              Date().timeIntervalSince(lastAirPodsCard) > 180,
              Date().timeIntervalSince(startedAt) > 3,
              let name = Self.pairedAirPodsName() else { return }
        lastAirPodsCard = Date()
        onAlert(Self.airPodsAlert(name: name, battery: battery, status: "Nearby"))
    }

    private static func pairedAirPodsName() -> String? {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.first(where: { isAirPods($0.name) })?.name
    }

    /// AirPods "proximity pairing" message, the one an iPhone reads to show its
    /// battery popup. Apple manufacturer data (company 0x004C), type 0x07:
    /// byte 6 holds the two buds (one per nibble), byte 7 the charging flags and
    /// the case. Each level is 0-10 (x10 %), 15 means unknown.
    nonisolated static func decodeProximity(_ data: Data) -> DeviceBattery? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 + 27, bytes[0] == 0x4C, bytes[1] == 0x00 else { return nil }
        let p = Array(bytes[2...])
        guard p[0] == 0x07, p[1] == 0x19, p[2] == 0x01 else { return nil }

        let model = UInt16(p[4]) << 8 | UInt16(p[3])
        let isMax = model == 0x200A
        // Which bud is reported first depends on which one is "primary".
        let flipped = !isMax && ((p[5] >> 4) & 0x02) == 0
        let high = Int(p[6] >> 4), low = Int(p[6] & 0x0F)
        let flags = Int(p[7] >> 4), caseRaw = Int(p[7] & 0x0F)

        func percent(_ raw: Int) -> Int? { raw <= 10 ? raw * 10 : nil }
        if isMax {
            return DeviceBattery(single: percent(high))
        }
        let battery = DeviceBattery(
            left: percent(flipped ? high : low),
            right: percent(flipped ? low : high),
            caseLevel: percent(caseRaw),
            leftCharging: flags & (flipped ? 0b0010 : 0b0001) != 0,
            rightCharging: flags & (flipped ? 0b0001 : 0b0010) != 0,
            caseCharging: flags & 0b0100 != 0)
        return battery.isEmpty ? nil : battery
    }

    // MARK: Symbols

    /// Headphones, speakers, keyboards, mice, trackpads, game controllers,
    /// Apple Pencil. Not phones, watches, tablets or computers, and not
    /// anything that doesn't say what it is.
    static func isAccessory(name: String, device: IOBluetoothDevice?) -> Bool {
        let n = name.lowercased()
        let devices = ["watch", "iphone", "ipad", "macbook", "imac", "mac mini", "mac studio", "mac pro", "’s mac", "'s mac", "vision pro"]
        if devices.contains(where: { n.contains($0) }) { return false }
        if isAirPods(name) { return true }
        if let device {
            switch UInt32(device.deviceClassMajor) {
            case 0x04, 0x05: return true   // audio / video, peripheral
            case 0x01, 0x02, 0x03, 0x07: return false  // computer, phone, network, wearable
            default: break
            }
        }
        let accessories = ["airpods", "beats", "headphone", "buds", "speaker", "homepod", "keyboard", "mouse",
                           "trackpad", "controller", "dualsense", "dualshock", "xbox", "joy-con", "pencil",
                           "bose", "sony", "jabra", "sennheiser", "jbl", "mx "]
        return accessories.contains(where: { n.contains($0) })
    }

    nonisolated static func isAirPods(_ name: String?) -> Bool {
        (name ?? "").lowercased().contains("airpods")
    }

    /// The device's own SF Symbol when it can be identified: first by its name,
    /// then by the device type it reports over Bluetooth. Anything else gets the
    /// generic wireless icon. Each candidate is checked to exist on this macOS
    /// version, newest names first.
    static func symbol(for name: String?, device: IOBluetoothDevice? = nil) -> String {
        let n = (name ?? "").lowercased()
        let byName: [(keys: [String], symbols: [String])] = [
            (["airpods max"], ["airpods.max", "airpodsmax"]),
            (["airpods pro"], ["airpods.pro", "airpodspro"]),
            (["airpods"], ["airpods"]),
            (["apple watch", "watch"], ["applewatch"]),
            (["iphone"], ["iphone"]),
            (["ipad"], ["ipad"]),
            (["macbook"], ["laptopcomputer"]),
            (["imac", "mac mini", "mac studio", "mac pro"], ["desktopcomputer"]),
            (["pencil"], ["applepencil"]),
            (["homepod"], ["homepod"]),
            (["trackpad"], ["rectangle.and.hand.point.up.left"]),
            (["magic mouse"], ["magicmouse", "computermouse"]),
            (["mouse", "mx master", "mx anywhere"], ["computermouse"]),
            (["keyboard", "mx keys"], ["keyboard"]),
            (["dialpad", "dial pad", "creative console"], ["dial.medium.fill", "dial.medium", "dial.min.fill"]),
            (["controller", "dualsense", "dualshock", "xbox", "joy-con", "pro controller"], ["gamecontroller"]),
            (["powerbeats"], ["beats.powerbeatspro", "beats.earphones", "earbuds"]),
            (["studio buds", "beats fit", "beats flex", "solo buds"], ["beats.studiobuds", "beats.earphones", "earbuds"]),
            (["beats"], ["beats.headphones", "headphones"]),
            (["buds", "earbuds", "wf-"], ["earbuds", "headphones"]),
            (["headphone", "wh-", "bose", "sony", "arctis", "nova", "jabra", "sennheiser"], ["headphones"]),
            (["speaker", "jbl", "boom", "soundlink", "sonos"], ["hifispeaker"]),
        ]
        if let match = byName.first(where: { entry in entry.keys.contains(where: { n.contains($0) }) }),
           let symbol = available(match.symbols) {
            return symbol
        }
        if let device, let symbol = symbol(forClassOf: device) { return symbol }
        return "dot.radiowaves.left.and.right"
    }

    /// Bluetooth "class of device": the type a device announces itself as.
    private static func symbol(forClassOf device: IOBluetoothDevice) -> String? {
        let major = UInt32(device.deviceClassMajor)
        let minor = UInt32(device.deviceClassMinor)
        switch major {
        case 0x01: return available(["desktopcomputer"])             // computer
        case 0x02: return available(["iphone"])                      // phone
        case 0x04:                                                   // audio / video
            return minor == 0x05 ? available(["hifispeaker"]) : available(["headphones"])
        case 0x05:                                                   // peripheral
            if minor & 0x10 != 0 { return available(["keyboard"]) }
            if minor & 0x20 != 0 { return available(["computermouse"]) }
            return available(["gamecontroller"])
        case 0x07: return available(["applewatch"])                  // wearable
        default: return nil
        }
    }

    private static func available(_ names: [String]) -> String? {
        names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }
}

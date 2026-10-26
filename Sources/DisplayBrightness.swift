import AppKit
import SwiftUI
import IOKit
import Carbon.HIToolbox
import Observation

// External monitor brightness. First choice is macOS's own brightness
// control (NativeBrightness below, the one Control Center's slider uses).
// Otherwise DDC/CI: the monitor's real backlight, set over the video cable
// the way MonitorControl and BetterDisplay do it.
//
// On Apple silicon the cable's I2C channel is reached through IOAVService,
// a private part of IOKit. The calls, addresses and packets below follow
// m1ddc (github.com/waydabber/m1ddc, sources/i2c.m), which was tested on
// this Mac mini (M4 Pro) with the Samsung U28R55 over USB-C to DisplayPort:
//   - IOAVServiceCreate gives the external display's service.
//   - DDC/CI lives at chip address 0x37, data address 0x51.
//   - Set VCP 0x10 (luminance): [0x84, 0x03, 0x10, hi, lo, checksum], sent twice.
//   - Get: send [0x82, 0x01, 0x10, checksum], wait, read 12 bytes; maximum in
//     bytes 6-7, current value in bytes 8-9 (big-endian).
// Private API: a future macOS could change it. If it stops working, the
// brightness controls just don't appear; nothing else is affected.

/// Talks DDC/CI to the external monitor. Every call blocks (the protocol
/// needs short waits), so they run on the controller's own queue.
final class DDCDisplay: @unchecked Sendable {
    private typealias CreateFunction = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias CreateWithServiceFunction = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create: CreateFunction? = dlsym(iokit, "IOAVServiceCreate").map { unsafeBitCast($0, to: CreateFunction.self) }
    private static let createWithService: CreateWithServiceFunction? =
        dlsym(iokit, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateWithServiceFunction.self) }
    private static let writeI2C: I2CFunction? = dlsym(iokit, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: I2CFunction.self) }
    private static let readI2C: I2CFunction? = dlsym(iokit, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: I2CFunction.self) }

    private static let chip: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    private static let luminance: UInt8 = 0x10
    private static let wait: useconds_t = 10_000

    private let service: CFTypeRef

    /// The external display's DDC channel, or nil when there's none (or the
    /// private calls are missing on this macOS). First the default one,
    /// exactly what `m1ddc set luminance` used in the test; failing that, an
    /// output macOS marks as external.
    init?() {
        guard Self.writeI2C != nil, Self.readI2C != nil,
              let service = Self.create?(kCFAllocatorDefault)?.takeRetainedValue() ?? Self.externalService()
        else { return nil }
        self.service = service
    }

    private static func externalService() -> CFTypeRef? {
        guard let createWithService else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var proxy = IOIteratorNext(iterator)
        while proxy != 0 {
            defer { IOObjectRelease(proxy); proxy = IOIteratorNext(iterator) }
            let location = IORegistryEntryCreateCFProperty(proxy, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let service = createWithService(kCFAllocatorDefault, proxy)?.takeRetainedValue() else { continue }
            return service
        }
        return nil
    }

    /// Current and maximum brightness, or nil if the monitor didn't answer.
    /// Some monitors answer slowly, so it tries a few times, waiting longer.
    func readBrightness() -> (current: Int, maximum: Int)? {
        Diag.count("brightness.ddc.read")
        for wait: useconds_t in [10_000, 40_000, 80_000] {
            if let value = readOnce(wait: wait) { return value }
        }
        return nil
    }

    private func readOnce(wait: useconds_t) -> (current: Int, maximum: Int)? {
        guard let writeI2C = Self.writeI2C, let readI2C = Self.readI2C else { return nil }
        var request: [UInt8] = [0x82, 0x01, Self.luminance, 0]
        request[3] = 0x6E ^ request[0] ^ request[1] ^ request[2]
        for _ in 0..<2 {
            usleep(Self.wait)
            let result = request.withUnsafeMutableBytes { buffer in
                writeI2C(service, Self.chip, Self.dataAddress, buffer.baseAddress!, UInt32(buffer.count))
            }
            guard result == kIOReturnSuccess else { return nil }
        }
        usleep(wait)
        var reply = [UInt8](repeating: 0, count: 12)
        let result = reply.withUnsafeMutableBytes { buffer in
            readI2C(service, Self.chip, Self.dataAddress, buffer.baseAddress!, UInt32(buffer.count))
        }
        guard result == kIOReturnSuccess else { return nil }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }

    @discardableResult
    func setBrightness(_ value: Int) -> Bool {
        guard let writeI2C = Self.writeI2C else { return false }
        let v = UInt16(clamping: max(0, value))
        var packet: [UInt8] = [0x84, 0x03, Self.luminance, UInt8(v >> 8), UInt8(v & 0xFF), 0]
        packet[5] = 0x6E ^ UInt8(Self.dataAddress) ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]
        for _ in 0..<2 {
            usleep(Self.wait)
            let result = packet.withUnsafeMutableBytes { buffer in
                writeI2C(service, Self.chip, Self.dataAddress, buffer.baseAddress!, UInt32(buffer.count))
            }
            guard result == kIOReturnSuccess else { return false }
        }
        return true
    }
}

/// The macOS way: DisplayServices, what Control Center's brightness slider
/// uses (Apple displays, and on recent macOS external monitors it can dim
/// itself). Private framework, looked up at run time; nil when it's missing
/// or can't change this display.
final class NativeBrightness: @unchecked Sendable {   // immutable after init
    private typealias CanChangeFunction = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let canChange: CanChangeFunction? =
        dlsym(framework, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanChangeFunction.self) }
    private static let getBrightness: GetFunction? =
        dlsym(framework, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setBrightness: SetFunction? =
        dlsym(framework, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFunction.self) }

    let display: CGDirectDisplayID

    init?(display: CGDirectDisplayID) {
        guard let canChange = Self.canChange, canChange(display), Self.setBrightness != nil else { return nil }
        self.display = display
        guard read() != nil else { return nil }
    }

    /// 0...1, as Control Center shows it.
    func read() -> Double? {
        guard let get = Self.getBrightness else { return nil }
        var value: Float = 0
        guard get(display, &value) == 0 else { return nil }
        Diag.count("brightness.native.read")
        return Double(value)
    }

    func write(_ value: Double) {
        Diag.count("brightness.native.write")
        _ = Self.setBrightness?(display, Float(min(max(value, 0), 1)))
    }
}

/// The external monitor's brightness for the island: the panel slider, two
/// shortcuts (for buttons on the MX Creative Console keypad) and the banner.
///
/// Uses macOS's own brightness control when it can (the same one as Control
/// Center's slider, so the two always agree), and talks DDC/CI to the monitor
/// itself otherwise. Writes are coalesced, so dragging the slider or holding
/// a key sends only the latest value. Nothing is sent while the Mac is locked
/// or its displays are asleep: a monitor command then can wake the display.
@MainActor
@Observable
final class DisplayBrightness {
    enum Method { case native, ddc }

    /// The monitor can be dimmed: the controls show.
    private(set) var isAvailable = false
    /// 0...1
    private(set) var level: Double = 0.5
    /// "U28R55", from macOS's name for the screen.
    private(set) var displayName = "Display"
    private(set) var method: Method?

    /// For Settings and the diagnostics report.
    var methodName: String {
        switch method {
        case .native: return "macOS brightness (\(displayName))"
        case .ddc: return "DDC/CI (\(displayName))"
        case nil: return "not available"
        }
    }

    /// A step from a shortcut or a brim:// link: show the banner.
    @ObservationIgnored var onStep: (@MainActor (Double) -> Void)?

    @ObservationIgnored private var native: NativeBrightness?
    @ObservationIgnored private var display: DDCDisplay?
    @ObservationIgnored private var maximum = 100
    private let queue = DispatchQueue(label: "app.brim.brightness")
    @ObservationIgnored private var pending: Double?
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var hotKeys: BrightnessHotKeys?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var running = false
    /// The displays connected the last time Brim looked, so a display merely
    /// waking up (which also posts "screen parameters changed") doesn't
    /// trigger a reconnect.
    @ObservationIgnored private var knownDisplays: [CGDirectDisplayID] = []
    @ObservationIgnored private var needsConnect = false
    @ObservationIgnored private var watchingQuiet = false

    /// Each step is a sixteenth, like an Apple display's brightness keys.
    nonisolated static let steps = 16
    nonisolated static let stepSize = 1.0 / Double(steps)

    /// The step the brightness is on, 0...16 ("Level 8" in the banner).
    var stepLevel: Int { Int((level / Self.stepSize).rounded()) }

    func start() {
        guard !running else { return }
        running = true
        connect()
        if !watchingQuiet {
            watchingQuiet = true
            // Catch up once the Mac is unlocked and lit again.
            QuietState.shared.whenActiveAgain { [weak self] in
                guard let self, self.running else { return }
                if self.needsConnect || DisplayBrightness.currentDisplays() != self.knownDisplays { self.connect() }
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
        let hotKeys = BrightnessHotKeys { [weak self] up in self?.step(up: up) }
        hotKeys.start()
        self.hotKeys = hotKeys
    }

    func stop() {
        running = false
        hotKeys?.stop()
        hotKeys = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        display = nil
        native = nil
        method = nil
        isAvailable = false
    }

    private static func currentDisplays() -> [CGDirectDisplayID] {
        NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }.sorted()
    }

    /// Only a real change (a display plugged in or out) reconnects.
    private func displaysChanged() {
        let now = Self.currentDisplays()
        guard now != knownDisplays else { return }
        Diag.event("Brightness: displays changed (\(knownDisplays.count) -> \(now.count))")
        connect()
    }

    /// Finds the monitor and how to dim it, and reads where it stands. Waits
    /// for a calm moment if the Mac is locked or dark.
    private func connect() {
        knownDisplays = Self.currentDisplays()
        guard !QuietState.shared.isQuiet else { needsConnect = true; return }
        needsConnect = false
        let external = NSScreen.screens.first { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            return id.map { CGDisplayIsBuiltin($0) == 0 } ?? false
        }
        displayName = external?.localizedName ?? "Display"
        let externalID = (external?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        // Brim keeps this object for its whole life, so holding it here is fine.
        queue.async { [self] in
            let native = externalID.flatMap { NativeBrightness(display: $0) }
            let nativeLevel = native?.read()
            // DDC only when macOS can't do it.
            let display = native == nil ? DDCDisplay() : nil
            let reading = display?.readBrightness()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.running else { return }
                    self.native = native
                    self.display = display
                    if let nativeLevel {
                        self.level = nativeLevel
                    } else if let reading {
                        self.maximum = reading.maximum
                        self.level = Double(reading.current) / Double(reading.maximum)
                    } else if let saved = UserDefaults.standard.object(forKey: "monitorBrightness") as? Double {
                        // Some monitors take DDC commands but never answer
                        // reads; Brim then starts from the last level it set.
                        self.level = saved
                    }
                    self.method = native != nil ? .native : (display != nil ? .ddc : nil)
                    self.isAvailable = self.method != nil
                    Diag.event("Brightness: \(self.methodName)")
                }
            }
        }
    }

    /// Catches up with changes made elsewhere (Control Center), before the
    /// slider shows or a step is taken. Free with the macOS method.
    func refresh() {
        if needsConnect, !QuietState.shared.isQuiet { connect(); return }
        if let native, let value = native.read() { level = value }
    }

    /// From the panel slider (no banner: you're looking at the slider).
    func setLevel(_ value: Double) {
        apply(value)
    }

    /// One step up or down (the shortcuts, brim://brightness?step=up).
    func step(up: Bool) {
        refresh()
        guard isAvailable else { return }
        // Snap to the sixteenths grid, then move one step.
        apply(Double(stepLevel + (up ? 1 : -1)) * Self.stepSize)
        onStep?(level)
    }

    /// Straight to a level, 0...1 (brim://brightness?set=50 sets 50%).
    func set(_ value: Double, announce: Bool) {
        refresh()
        guard isAvailable else { return }
        apply(value)
        if announce { onStep?(level) }
    }

    private func apply(_ value: Double) {
        guard isAvailable, !QuietState.shared.isQuiet else { return }
        level = min(max(value, 0), 1)
        UserDefaults.standard.set(level, forKey: "monitorBrightness")
        pending = level
        sendPending()
    }

    /// One write at a time, always the newest value.
    private func sendPending() {
        guard !writing, let value = pending else { return }
        let native = self.native, display = self.display, maximum = self.maximum
        guard native != nil || display != nil else { return }
        pending = nil
        writing = true
        queue.async { [self] in
            if let native {
                native.write(value)
            } else if let display {
                Diag.count("brightness.ddc.write")
                display.setBrightness(Int((value * Double(maximum)).rounded()))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.writing = false
                    self.sendPending()
                }
            }
        }
    }
}

extension NotchAlert {
    /// The brightness banner, laid out like the keyboard backlight one: the
    /// sun (Apple's SF Symbols), the level and the bar.
    static func brightnessBanner(_ level: Double, step: Int, display: String) -> NotchAlert {
        let symbol: String
        // Filled throughout: the small sun up to halfway, the big one from
        // level 8 (the outline only at the very lowest step, in gray).
        if step <= 0 { symbol = "sun.min" }
        else if level < 0.5 { symbol = "sun.min.fill" }
        else { symbol = "sun.max.fill" }
        return NotchAlert(symbol: symbol, tint: step <= 0 ? .gray : .white,
                          title: display, subtitle: step <= 0 ? "Lowest" : "Level \(step)",
                          duration: 2, brightness: level, liveKey: "brightness")
    }
}

/// Two system-wide shortcuts for brightness: Control-Option-Command-Up and
/// Control-Option-Command-Down. Meant for two buttons on the MX Creative
/// Console keypad: in Logi Options+, give each button a keyboard shortcut
/// action with one of these. Registered as hot keys (the way menu bar apps
/// register theirs), which needs no permission and never sees other keys.
final class BrightnessHotKeys: @unchecked Sendable {
    private let onPress: @MainActor (Bool) -> Void
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    /// The shortcut, shown in Settings and the README.
    static let upLabel = "\u{2303}\u{2325}\u{2318}\u{2191}"
    static let downLabel = "\u{2303}\u{2325}\u{2318}\u{2193}"
    private static let signature: OSType = 0x48414C4F   // "HALO"
    private static let upID: UInt32 = 1
    private static let downID: UInt32 = 2

    init(onPress: @escaping @MainActor (Bool) -> Void) {
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
            guard id.signature == BrightnessHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<BrightnessHotKeys>.fromOpaque(context).takeUnretainedValue()
            let up = id.id == BrightnessHotKeys.upID
            MainActor.assumeIsolated { me.onPress(up) }   // Carbon calls this on the main thread
            return noErr
        }, 1, &type, context, &handler)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        for (key, id) in [(kVK_UpArrow, Self.upID), (kVK_DownArrow, Self.downID)] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key), modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { appLog.error("Brightness shortcut \(id) is taken by another app") }
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

// BacklightProbe: a one-off test for the keyboard backlight banner.
//
// Connects to a Logitech keyboard over HID++ 2.0 (Bluetooth), looks up the
// Backlight2 feature (0x1982) through the Root feature, prints the backlight
// state, then listens for 20 seconds so you can press the backlight keys and
// see whether the keyboard sends its own change notifications.
//
// Build and run from the Halo folder:
//   swiftc -O Tools/BacklightProbe.swift -o build/backlight-probe -framework IOKit
//   ./build/backlight-probe
//
// Terminal needs Input Monitoring (System Settings > Privacy & Security >
// Input Monitoring). The first run asks for it.
//
// Report delivery follows async-hid (OpenLogi's macOS HID layer).
//
// Protocol details, checked in Solaar (lib/logitech_receiver: base.py,
// hidpp20.py, settings_templates.py, notifications.py) and OpenLogi
// (crates/openlogi-hidpp/src/feature/backlight.rs, reprog_controls.rs,
// crates/openlogi-hid/src/transport.rs):
//   - Bluetooth LE devices expose HID++ on vendor page 0xFF43, usage 0x0202,
//     long reports only: [0x11, 0xFF, featureIndex, function<<4 | swid, 16 params].
//   - Root (index 0): function 0 getFeature(id hi, id lo) -> index, type, version;
//     function 1 getProtocolVersion(0, 0, ping) -> major, minor, ping.
//   - Backlight2 0x1982: function 0 getBacklightConfig, 1 setBacklightConfig,
//     2 getBacklightInfo, 3 setBacklightEffect. Event 0 = backlightInfoEvent,
//     same layout as getBacklightInfo: levels, level, status, effect.
//   - Errors: [0x11, dev, 0xFF, featureIndex, function|swid, code].

import Foundation
import IOKit
import IOKit.hid

let logitech = 0x046D
let softwareID: UInt8 = 0x0A          // ours; notifications use 0, Options+ its own
let reportLength = 20

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

setvbuf(stdout, nil, _IOLBF, 0)      // print each line immediately

// Reports arrive on a private serial dispatch queue, no run loop involved.
// This is how async-hid (the HID layer OpenLogi uses on macOS) does it:
// IOHIDDeviceSetDispatchQueue + IOHIDDeviceActivate, an input buffer sized
// from kIOHIDMaxInputReportSizeKey, and plain synchronous IOHIDDeviceSetReport.
let hidQueue = DispatchQueue(label: "BacklightProbe.hid")

// Ctrl+C: finish cleanly so the key reports get switched back off.
var stopRequested: sig_atomic_t = 0
signal(SIGINT) { _ in stopRequested = 1 }

// MARK: - Permission

switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
case kIOHIDAccessTypeGranted:
    print("Input Monitoring: granted")
case kIOHIDAccessTypeDenied:
    print("Input Monitoring is denied for this app (Terminal).")
    print("Turn it on in System Settings > Privacy & Security > Input Monitoring, then run again.")
    exit(1)
default:
    print("Asking for Input Monitoring...")
    let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    print(granted ? "Granted. Run the probe again." : "Not granted. Turn it on in System Settings > Privacy & Security > Input Monitoring.")
    exit(granted ? 0 : 1)
}

func runningProcesses(_ names: [String]) -> [String] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    guard (try? task.run()) != nil else { return [] }
    // Read before waiting: a long process list fills the pipe and ps would block forever.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    return names.filter { name in out.split(separator: "\n").contains { $0.hasSuffix("/" + name) || $0 == name } }
}

// Is Logi Options+ running? It may share the keyboard; see the note at the end.
print("Checking for Logi Options+...")
let optionsPlus = runningProcesses(["logioptionsplus_agent", "logioptionsplus", "LogiPluginService"])
print("Logi Options+ running: \(optionsPlus.isEmpty ? "no" : "yes (\(optionsPlus.joined(separator: ", ")))")")

// MARK: - Device

final class Keyboard {
    let device: IOHIDDevice
    let name: String
    let maxInputReport: Int
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int
    // Touched only on hidQueue.
    private var pending: (feature: UInt8, function: UInt8)?
    private var reply: [UInt8]?
    private let replied = DispatchSemaphore(value: 0)
    var reportCounts: [UInt8: Int] = [:]
    var onNotification: (([UInt8]) -> Void)?    // called on hidQueue

    init(device: IOHIDDevice) {
        self.device = device
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        maxInputReport = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        bufferSize = max(maxInputReport, 64)
        buffer = .allocate(capacity: bufferSize)
    }

    /// Opens the device and starts delivering its reports on hidQueue.
    func open() -> Bool {
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            print("  opening failed: 0x\(String(UInt32(bitPattern: r), radix: 16))")
            if UInt32(bitPattern: r) == 0xE00002C5 { print("  Another app holds it exclusively (Logi Options+?).") }
            return false
        }
        IOHIDDeviceSetDispatchQueue(device, hidQueue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let keyboard = Unmanaged<Keyboard>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // macOS normally includes the report ID as the first byte; add it if not.
            if bytes.first != UInt8(truncatingIfNeeded: reportID) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
            keyboard.received(bytes)
        }, context)
        IOHIDDeviceActivate(device)
        return true
    }

    private func received(_ bytes: [UInt8]) {
        if let id = bytes.first { reportCounts[id, default: 0] += 1 }
        guard bytes.count >= 4, bytes[0] == 0x11 || bytes[0] == 0x10 else { return }
        if let p = pending {
            let call = (p.function << 4) | softwareID
            if (bytes[2] == p.feature && bytes[3] == call) || (bytes[2] == 0xFF && bytes.count >= 6 && bytes[3] == p.feature && bytes[4] == call) {
                pending = nil
                reply = bytes
                replied.signal()
                return
            }
        }
        onNotification?(bytes)      // events (swid 0) and other apps' traffic (their swid)
    }

    /// Sends a long HID++ 2.0 request and waits for the matching reply.
    /// Returns the 16 parameter bytes, or nil on timeout / error.
    func call(feature: UInt8, function: UInt8, _ params: [UInt8] = [], timeout: TimeInterval = 2) -> [UInt8]? {
        var report = [UInt8](repeating: 0, count: reportLength)
        report[0] = 0x11
        report[1] = 0xFF
        report[2] = feature
        report[3] = (function << 4) | softwareID
        for (i, b) in params.prefix(16).enumerated() { report[4 + i] = b }
        hidQueue.sync {
            while replied.wait(timeout: .now()) == .success {}    // drop a stale signal
            pending = (feature, function)
            reply = nil
        }
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, report, report.count)
        guard result == kIOReturnSuccess else {
            print("  write failed: 0x\(String(UInt32(bitPattern: result), radix: 16))")
            hidQueue.sync { pending = nil }
            return nil
        }
        _ = replied.wait(timeout: .now() + timeout)
        let answer: [UInt8]? = hidQueue.sync { pending = nil; return reply }
        guard let r = answer else { print("  no reply to feature \(feature) function \(function)"); return nil }
        if r[2] == 0xFF {
            print("  HID++ error \(r[5]) (\(errorName(r[5]))) on feature \(feature) function \(function)")
            return nil
        }
        return Array(r[4..<min(r.count, 20)])
    }

    func errorName(_ code: UInt8) -> String {
        ["no error", "unknown", "invalid argument", "out of range", "hardware error", "Logitech internal",
         "invalid feature index", "invalid function", "busy", "unsupported"][Int(min(code, 9))]
    }
}

// MARK: - Find it

print("Looking for Logitech keyboards...")

// A Bluetooth keyboard is one HID device with several collections: the
// keyboard is its primary usage and the HID++ channel is a secondary one, so
// match every device and check all of its usage pairs ourselves.
func prop<T>(_ d: IOHIDDevice, _ key: String) -> T? { IOHIDDeviceGetProperty(d, key as CFString) as? T }
func usagePairs(_ d: IOHIDDevice) -> [(page: Int, usage: Int)] {
    var pairs: [(page: Int, usage: Int)] = []
    if let list: [[String: Any]] = prop(d, kIOHIDDeviceUsagePairsKey) {
        for p in list {
            if let page = p[kIOHIDDeviceUsagePageKey] as? Int, let usage = p[kIOHIDDeviceUsageKey] as? Int { pairs.append((page, usage)) }
        }
    }
    if pairs.isEmpty, let page: Int = prop(d, kIOHIDPrimaryUsagePageKey), let usage: Int = prop(d, kIOHIDPrimaryUsageKey) {
        pairs.append((page, usage))
    }
    return pairs
}
func hasHIDPP(_ d: IOHIDDevice) -> Bool {
    usagePairs(d).contains { ($0.page == 0xFF43 && $0.usage == 0x0202) || ($0.page == 0xFF00 && ($0.usage == 0x0001 || $0.usage == 0x0002)) }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil)
var all = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
if all.isEmpty {
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    all = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
}

let logi = all.filter { d in
    let vendor: Int = prop(d, kIOHIDVendorIDKey) ?? 0
    let name: String = prop(d, kIOHIDProductKey) ?? ""
    return vendor == logitech || name.localizedCaseInsensitiveContains("MX") || name.localizedCaseInsensitiveContains("Logi")
}
print("HID devices seen: \(all.count). Logitech-looking ones:")
if logi.isEmpty { print("  none") }
for d in logi {
    let name: String = prop(d, kIOHIDProductKey) ?? "?"
    let vendor: Int = prop(d, kIOHIDVendorIDKey) ?? 0
    let pid: Int = prop(d, kIOHIDProductIDKey) ?? 0
    let transport: String = prop(d, kIOHIDTransportKey) ?? "?"
    let pairs = usagePairs(d).map { String(format: "%04X/%04X", $0.page, $0.usage) }.joined(separator: " ")
    print(String(format: "  %@  vendor 0x%04X  pid 0x%04X  %@  usages %@", name, vendor, pid, transport, pairs))
}

let devices = logi.filter(hasHIDPP)
if devices.isEmpty {
    print("\nNone of these has a HID++ channel macOS lets us see. Send me the list above.")
    exit(1)
}

// Prefer the MX Keys Mini (Bluetooth product ID 0xB369), else any keyboard with the feature.
func score(_ d: IOHIDDevice) -> Int {
    let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0
    let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? ""
    return pid == 0xB369 ? 2 : (name.contains("Keys") ? 1 : 0)
}
let ordered = devices.sorted { score($0) > score($1) }

var tried: [Keyboard] = []     // kept alive: their input callbacks point at them
var found: Keyboard?
var backlightIndex: UInt8 = 0
for d in ordered {
    let k = Keyboard(device: d)
    tried.append(k)
    print("\nTrying \(k.name)...  (max input report \(k.maxInputReport) bytes)")
    guard k.open() else { continue }
    guard let proto = k.call(feature: 0x00, function: 1, [0, 0, 0x5A]) else { continue }
    print("  HID++ \(proto[0]).\(proto[1]) (ping \(proto[2] == 0x5A ? "ok" : "mismatch"))")
    guard let f = k.call(feature: 0x00, function: 0, [0x19, 0x82]) else { continue }
    if f[0] == 0 {
        print("  Feature 0x1982 (Backlight2): not present")
        continue
    }
    print("  Feature 0x1982 (Backlight2): present at index \(f[0]), version \(f[2])")
    found = k
    backlightIndex = f[0]
    break
}

guard let keyboard = found else {
    print("\nNo connected keyboard reported Backlight2.")
    exit(1)
}

// MARK: - Read the backlight

let statusNames = ["disabled by software", "disabled (battery critical)", "automatic (light sensor)",
                   "automatic, saturated (off)", "temporary manual (keys)", "permanent manual (software)"]
let modeNames = ["none", "automatic", "temporary manual", "permanent manual"]

if let c = keyboard.call(feature: backlightIndex, function: 0) {
    print("\ngetBacklightConfig  [\(hex(c))]")
    let mode = Int((c[1] >> 3) & 0x03)
    print("  enabled: \(c[0] & 1 == 1)")
    print("  mode: \(mode) (\(modeNames[mode]))")
    print("  supports: auto \(c[2] & 0x08 != 0), temporary manual \(c[2] & 0x10 != 0), permanent manual \(c[2] & 0x20 != 0)")
    print("  manual level: \(c[5])")
}
func printInfo(_ i: [UInt8], prefix: String) {
    let status = Int(i[2])
    print("\(prefix) level \(i[1]) of \(max(0, Int(i[0]) - 1))  (\(i[0]) levels)  status \(status) (\(status < statusNames.count ? statusNames[status] : "?"))")
}
if let i = keyboard.call(feature: backlightIndex, function: 2) {
    print("getBacklightInfo    [\(hex(i))]")
    printInfo(i, prefix: " ")
}

// Backlight keys: can they report presses without losing their normal action?
// REPROG_CONTROLS_V4 (0x1B04), checked in OpenLogi reprog_controls.rs:
//   function 2 getCidReporting(cid hi, cid lo) -> [cid, flags, remap, flags2]
//     flags bit0 diverted; flags2 (byte 5) bit0 analytics key events
//   function 3 setCidReporting: byte 5 bit1 = "change analytics", bit0 = new value
//   event 2 analyticsKeyEvents: up to 5 x (cid hi, cid lo, event)
let backlightKeys: [UInt16: String] = [0xE2: "Backlight Down", 0xE3: "Backlight Up"]
var reprogIndex: UInt8 = 0
var originalAnalytics: [UInt16: Bool] = [:]
if let r = keyboard.call(feature: 0x00, function: 0, [0x1B, 0x04]), r[0] != 0 {
    reprogIndex = r[0]
    print("Reprogrammable keys feature (0x1B04) at index \(reprogIndex)")
    for cid in backlightKeys.keys.sorted() {
        guard let rep = keyboard.call(feature: reprogIndex, function: 2, [UInt8(cid >> 8), UInt8(cid & 0xFF)]) else { continue }
        let diverted = rep[2] & 0x01 != 0
        let analytics = rep[5] & 0x01 != 0
        originalAnalytics[cid] = analytics
        print(String(format: "Key 0x%02X (%@): diverted %@, analytics %@", cid, backlightKeys[cid]!,
                     diverted ? "yes (an app handles it)" : "no", analytics ? "on" : "off"))
    }
    // Turn analytics on: the keys keep working and also tell us each press.
    for cid in originalAnalytics.keys where originalAnalytics[cid] == false {
        if keyboard.call(feature: reprogIndex, function: 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), 0, 0, 0, 0b11]) != nil {
            print(String(format: "  turned on key reports for 0x%02X", cid))
        }
    }
}

func restoreKeys() {
    for (cid, was) in originalAnalytics where was == false {
        _ = keyboard.call(feature: reprogIndex, function: 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), 0, 0, 0, 0b10])
    }
    if !originalAnalytics.isEmpty { print("Key reports restored.") }
}

// MARK: - Listen

print("\nPress the backlight keys now: up 3 times, then down 3 times, slowly. Then type a few letters.")
print("(listening for 20 seconds, Ctrl+C stops early)")
var events = 0
var keyPresses = 0
var lastLevel: UInt8? = nil
var readAt: Date? = nil
let started = Date()
func stamp() -> String { String(format: "%5.1fs", Date().timeIntervalSince(started)) }


let handler: ([UInt8]) -> Void = { bytes in
    let swid = bytes[2] == 0xFF ? bytes[4] & 0x0F : bytes[3] & 0x0F
    if swid == softwareID { return }    // a late reply to us
    let function = bytes[3] >> 4
    if swid != 0 {
        print("\(stamp())  other app (swid \(swid)) on feature \(bytes[2] == 0xFF ? bytes[3] : bytes[2])  [\(hex(bytes))]")
        return
    }
    if bytes[2] == backlightIndex && function == 0 {
        events += 1
        lastLevel = bytes[5]
        printInfo(Array(bytes[4...]), prefix: "\(stamp())  backlight event:")
    } else if bytes[2] == reprogIndex && function == 2 {
        var i = 4
        while i + 2 < min(bytes.count, 19) {
            let cid = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
            if let name = backlightKeys[cid] {
                keyPresses += 1
                print("\(stamp())  key: \(name), event \(bytes[i + 2])")
                readAt = Date().addingTimeInterval(0.15)    // let the keyboard apply it first
            }
            i += 3
        }
    } else {
        print("\(stamp())  other event: feature \(bytes[2]) event \(function)  [\(hex(bytes))]")
    }
}
hidQueue.sync { keyboard.onNotification = handler }

let end = Date().addingTimeInterval(20)
var nextPoll = Date()
var nextBeat = Date().addingTimeInterval(5)
var polls = 0, pollChanges = 0, pollFailures = 0
// --no-poll turns polling off; --poll SECONDS sets the interval (default 0.5).
let polling = !CommandLine.arguments.contains("--no-poll")
var pollInterval = 0.5
if let i = CommandLine.arguments.firstIndex(of: "--poll"), i + 1 < CommandLine.arguments.count,
   let v = Double(CommandLine.arguments[i + 1]), v > 0 { pollInterval = v }
print(polling ? "(asking the keyboard every \(pollInterval)s)" : "(polling off)")
// The handler above runs on hidQueue, so shared state is read and written there.
func countsText() -> String {
    hidQueue.sync { keyboard.reportCounts }.sorted { $0.key < $1.key }
        .map { String(format: "ID 0x%02X: %d", $0.key, $0.value) }.joined(separator: ", ")
}
func noteLevel(_ level: UInt8) -> (first: Bool, changed: Bool) {
    hidQueue.sync {
        defer { lastLevel = level }
        return (lastLevel == nil, lastLevel != nil && lastLevel != level)
    }
}
while Date() < end && stopRequested == 0 {
    Thread.sleep(forTimeInterval: 0.05)
    if Date() >= nextBeat {
        nextBeat = Date().addingTimeInterval(5)
        print("\(stamp())  still listening. Reports so far: \(countsText())")
    }
    let due: Bool = hidQueue.sync {
        guard let t = readAt, Date() >= t else { return false }
        readAt = nil
        return true
    }
    if due {
        if let i = keyboard.call(feature: backlightIndex, function: 2) {
            let note = noteLevel(i[1])
            printInfo(i, prefix: "\(stamp())  re-read\(note.changed ? "" : " (unchanged)"):")
        }
    } else if polling, Date() >= nextPoll {
        // Ask the keyboard twice a second as well, to see if it changes without telling us.
        nextPoll = Date().addingTimeInterval(pollInterval)
        polls += 1
        if let i = keyboard.call(feature: backlightIndex, function: 2, timeout: 0.5) {
            if noteLevel(i[1]).changed {
                pollChanges += 1
                printInfo(i, prefix: "\(stamp())  poll saw a change:")
            }
        } else { pollFailures += 1 }
    }
}

print("")
restoreKeys()
let (eventCount, keyCount) = hidQueue.sync { (events, keyPresses) }
print("Done after \(String(format: "%.0f", Date().timeIntervalSince(started)))s. Backlight events: \(eventCount). Backlight key reports: \(keyCount).")
print("Polls: \(polls), changes seen by polling: \(pollChanges), failed polls: \(pollFailures)")
print("Reports received by report ID: \(countsText())")
if !optionsPlus.isEmpty { print("Options+ was running during this test.") }

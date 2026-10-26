import AppKit
import AVFoundation
import Carbon
import CoreBluetooth
import EventKit
import IOKit.hid
import Speech
import SwiftUI

// What Brim may use on this Mac, for Settings > Permissions: each permission,
// what it's for, and whether macOS has allowed it. Only reads the status;
// asking happens where a feature needs it.

enum PermissionStatus {
    case allowed
    case denied
    case notAsked
    /// Allowed in part (Calendars: add events only).
    case partly(String)
    /// Can't be told until it's used (an app that isn't running).
    case whenUsed

    var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Not Allowed"
        case .notAsked: return "Not Asked Yet"
        case .partly(let text): return text
        case .whenUsed: return "Asks When Used"
        }
    }

    var symbol: String {
        switch self {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notAsked, .whenUsed: return "circle.dashed"
        case .partly: return "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .allowed: return .green
        case .denied: return .red
        case .notAsked, .whenUsed: return .secondary
        case .partly: return .orange
        }
    }

    /// Worth a button to System Settings.
    var needsAttention: Bool {
        switch self {
        case .denied, .partly: return true
        default: return false
        }
    }
}

struct PermissionItem: Identifiable {
    let id: String
    let title: String
    let purpose: String
    let symbol: String
    let color: Color
    let status: PermissionStatus
    /// The page in System Settings > Privacy & Security.
    let anchor: String

    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

@MainActor
enum Permissions {
    static func current() -> [PermissionItem] {
        var items: [PermissionItem] = [
            PermissionItem(id: "disk", title: "Full Disk Access",
                           purpose: "Reading your Mac's notifications to show them in the island.",
                           symbol: "externaldrive.fill", color: .gray,
                           status: NotificationMirror.hasAccess ? .allowed : .denied,
                           anchor: "Privacy_AllFiles"),
            PermissionItem(id: "calendars", title: "Calendars",
                           purpose: "Upcoming meetings and their Join links.",
                           symbol: "calendar", color: .red,
                           status: events(.event), anchor: "Privacy_Calendars"),
            PermissionItem(id: "reminders", title: "Reminders",
                           purpose: "Reminders due soon, and ticking them off.",
                           symbol: "checklist", color: .orange,
                           status: events(.reminder), anchor: "Privacy_Reminders"),
            PermissionItem(id: "camera", title: "Camera",
                           purpose: "The Mirror in the panel, only while it's open.",
                           symbol: "video.fill", color: .green,
                           status: capture(.video), anchor: "Privacy_Camera"),
            PermissionItem(id: "microphone", title: "Microphone",
                           purpose: "The teleprompter's Follow My Voice, while it listens.",
                           symbol: "mic.fill", color: .orange,
                           status: capture(.audio), anchor: "Privacy_Microphone"),
            PermissionItem(id: "speech", title: "Speech Recognition",
                           purpose: "Following your place in a script, on this Mac only.",
                           symbol: "waveform", color: .purple,
                           status: speech(), anchor: "Privacy_SpeechRecognition"),
            PermissionItem(id: "input", title: "Input Monitoring",
                           purpose: "Talking to Logitech devices for the backlight and battery banners. Never reads your typing.",
                           symbol: "keyboard.fill", color: .gray,
                           status: inputMonitoring(), anchor: "Privacy_ListenEvent"),
            PermissionItem(id: "bluetooth", title: "Bluetooth",
                           purpose: "Banners when devices connect, and the AirPods battery card.",
                           symbol: "dot.radiowaves.left.and.right", color: .blue,
                           status: bluetooth(), anchor: "Privacy_Bluetooth"),
        ]
        // Automation: only for the music apps on this Mac.
        for (id, name, color) in [("com.apple.Music", "Music", Color.pink), ("com.spotify.client", "Spotify", Color.green)]
        where AppLocator.url(for: id) != nil {
            items.append(PermissionItem(id: id, title: "Control \(name)",
                                        purpose: "What's playing in \(name), and its playback buttons.",
                                        symbol: "music.note", color: color,
                                        status: automation(id), anchor: "Privacy_Automation"))
        }
        return items
    }

    private static func events(_ type: EKEntityType) -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return .allowed
        case .writeOnly: return .partly("Add Only")
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        @unknown default: return .allowed
        }
    }

    private static func capture(_ type: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        @unknown default: return .notAsked
        }
    }

    private static func speech() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        @unknown default: return .notAsked
        }
    }

    private static func inputMonitoring() -> PermissionStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .allowed
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notAsked
        }
    }

    private static func bluetooth() -> PermissionStatus {
        switch CBManager.authorization {
        case .allowedAlways: return .allowed
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        @unknown default: return .notAsked
        }
    }

    /// Whether Brim may send Apple Events to an app. macOS can only tell
    /// while the app is running.
    private static func automation(_ bundleID: String) -> PermissionStatus {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return .whenUsed }
        var target = AEAddressDesc()
        let created = bundleID.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, Int(strlen(pointer)), &target)
        }
        guard created == noErr else { return .whenUsed }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard),
                                                           AEEventID(typeWildCard), false)
        switch status {
        case noErr: return .allowed
        case -1743: return .denied      // errAEEventNotPermitted
        case -1744: return .notAsked    // errAEEventWouldRequireUserConsent
        default: return .whenUsed
        }
    }
}

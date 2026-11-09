import AppKit

/// Your iPhone's notifications, as macOS shows them on the Mac when "Allow
/// notifications from iPhone" is on (System Settings › Notifications).
///
/// macOS keeps them apart from the Mac's own, one archive per iPhone app:
/// Group Containers/group.com.apple.UserNotifications/Library/UserNotifications/
/// Remote/default/<app>/DeliveredNotifications.plist. Brim reads them with the
/// Full Disk Access it already has, read-only, and never changes them. Apps
/// that are on the Mac too (WhatsApp, Messages, Mail...) are skipped: the Mac
/// already notifies for those, so nothing shows twice.
///
/// It's Apple's private storage, like the Live Activities list. If a macOS
/// update moves or changes it, iPhone notifications just stop showing.
@MainActor
final class IPhoneNotificationMirror {
    /// A notification and whether it's new (a banner) or old news (the list only).
    private let onAlert: @MainActor (NotchAlert, Bool) -> Void

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.UserNotifications/Library/UserNotifications/Remote/default")

    /// Each app's archive and when it last changed.
    private var stamps: [String: Date] = [:]
    /// Notifications already handled, by their own ID.
    private var seen: Set<String> = []
    private var timer: Timer?
    private var names: [String: String] = [:]

    init(onAlert: @escaping @MainActor (NotchAlert, Bool) -> Void) {
        self.onAlert = onAlert
    }

    func start() {
        guard timer == nil else { return }
        guard FileManager.default.fileExists(atPath: Self.folder.path) else {
            NotificationLog.write("iPhone notifications: none on this Mac (Allow notifications from iPhone is off, or no iPhone)")
            // Look again now and then: the setting may be switched on later.
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, FileManager.default.fileExists(atPath: Self.folder.path) else { return }
                    self.stop()
                    self.start()
                }
            }
            return
        }
        // What's there already: into the list (the last few hours, minus
        // anything you cleared), no banners.
        var restored = 0
        for (path, date) in Self.archives() {
            stamps[path] = date
            for alert in read(path) {
                // Already in the list from an earlier start: not again.
                guard seen.insert(alert.key).inserted else { continue }
                if abs(alert.alert.date.timeIntervalSinceNow) < 6 * 60 * 60, !ClearedNotifications.wasCleared(alert.alert) {
                    onAlert(alert.alert, false)
                    restored += 1
                }
            }
        }
        NotificationLog.write("iPhone notifications: watching, restored \(restored) recent ones to the list")
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Watching

    /// Every app's archive with its modification date.
    private static func archives() -> [(String, Date)] {
        let manager = FileManager.default
        let apps = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        return apps.compactMap { app in
            let path = folder.appendingPathComponent(app).appendingPathComponent("DeliveredNotifications.plist").path
            guard let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
            return (path, date)
        }
    }

    /// Only archives that changed since the last look are opened.
    private func check() {
        guard !QuietState.shared.isDark else { return }
        Diag.count("iphoneNotifications.check")
        for (path, date) in Self.archives() where stamps[path] != date {
            stamps[path] = date
            Diag.count("iphoneNotifications.read")
            for found in read(path) where !seen.contains(found.key) {
                seen.insert(found.key)
                let age = abs(found.alert.date.timeIntervalSinceNow)
                let isNew = age < 120
                NotificationLog.write("IPHONE   \(found.alert.bundleID ?? "?")  \(NotificationLog.short(found.alert.title))  message: \(found.alert.body?.count ?? 0) chars  -> \(isNew ? "banner" : "history only (\(Int(age))s old)")")
                onAlert(found.alert, isNew)
            }
        }
        if seen.count > 3_000 { seen.removeAll() }   // a long-running Mac: start the list afresh
    }

    // MARK: Reading

    private struct Found {
        let key: String
        let alert: NotchAlert
    }

    /// The notifications in one app's archive, newest first, as Brim alerts.
    private func read(_ path: String) -> [Found] {
        guard let data = FileManager.default.contents(atPath: path),
              let list = KeyedArchive.decode(data) as? [Any] else { return [] }
        return list.compactMap { item in
            guard let n = item as? [String: Any] else { return nil }
            return makeAlert(n)
        }
    }

    private func makeAlert(_ n: [String: Any]) -> Found? {
        func text(_ key: String) -> String? {
            guard let t = (n[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        guard let bundleID = Self.bundleID(in: n), let id = text("AppNotificationIdentifier") else { return nil }
        // On the Mac too: the Mac's own notification covers it.
        guard !Self.onThisMac(bundleID) else { return nil }
        let title = text("AppNotificationTitle")
        let subtitle = text("AppNotificationSubtitle")
        let body = text("AppNotificationMessage")
        guard title != nil || body != nil else { return nil }
        let date = n["AppNotificationCreationDate"] as? Date ?? Date()
        let name = appName(for: bundleID)
        var alert = NotchAlert(symbol: "iphone", tint: .accentColor,
                               title: title ?? name, subtitle: subtitle, body: body,
                               appIcon: IPhoneAppIcons.icon(for: bundleID), appName: name,
                               bundleID: bundleID, duration: 5, date: date)
        alert.fromiPhone = true
        return Found(key: id, alert: alert)
    }

    /// The iPhone app that sent it: in the event details macOS keeps with
    /// each notification.
    private static func bundleID(in n: [String: Any]) -> String? {
        func search(_ value: Any?, depth: Int) -> String? {
            guard depth < 5 else { return nil }
            if let dict = value as? [String: Any] {
                if let id = dict["bundleIdentifier"] as? String, !id.isEmpty { return id }
                for child in dict.values { if let id = search(child, depth: depth + 1) { return id } }
            }
            return nil
        }
        if let id = search(n["EventBehavior"], depth: 0) { return id }
        // Messaging apps also name their notification extension.
        if let ext = n["CommunicationContextBundleIdentifier"] as? String, !ext.isEmpty {
            return ext.replacingOccurrences(of: ".notificationextension", with: "")
                .replacingOccurrences(of: ".NotificationServiceExtension", with: "")
        }
        return nil
    }

    /// iPhone apps whose Mac version has another ID.
    private static let macTwins: [String: String] = [
        "com.apple.mobilemail": "com.apple.mail",
        "com.apple.mobilecal": "com.apple.iCal",
        "com.apple.mobilenotes": "com.apple.Notes",
        "com.apple.mobileslideshow": "com.apple.Photos",
        "com.apple.mobilephone": "com.apple.FaceTime",
        "com.apple.mobiletimer": "com.apple.clock",
        "com.apple.reminders": "com.apple.reminders",
    ]

    private static func onThisMac(_ bundleID: String) -> Bool {
        if AppLocator.url(for: bundleID) != nil { return true }
        if let twin = macTwins[bundleID.lowercased()] ?? macTwins[bundleID], AppLocator.url(for: twin) != nil { return true }
        return false
    }

    /// "com.burbn.instagram" → "Instagram", unless macOS knows the app's name.
    private func appName(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        let known: [String: String] = ["com.burbn.instagram": "Instagram", "com.glovo.glovo": "Glovo",
                                       "com.duolingo.DuolingoMobile": "Duolingo", "com.facebook.Facebook": "Facebook",
                                       "com.atebits.Tweetie2": "X", "com.zhiliaoapp.musically": "TikTok",
                                       "ph.telegra.Telegraph": "Telegram", "com.toyopagroup.picaboo": "Snapchat"]
        let name = known[bundleID]
            ?? bundleID.split(separator: ".").last.map { String($0).replacingOccurrences(of: "Mobile", with: "").capitalized }
            ?? "iPhone"
        names[bundleID] = name
        return name
    }
}

/// Reads an NSKeyedArchiver archive into plain dictionaries, arrays, strings,
/// numbers, dates and data, whatever classes it was written with, so an
/// object type Brim doesn't know can't stop it.
enum KeyedArchive {
    static func decode(_ data: Data) -> Any? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any],
              let root = top["root"] else { return nil }
        return resolve(root, objects, depth: 0)
    }

    private static func resolve(_ value: Any, _ objects: [Any], depth: Int) -> Any? {
        guard depth < 12 else { return nil }
        var value = value
        if let index = uid(value) {
            guard index < objects.count else { return nil }
            value = objects[index]
        }
        if let string = value as? String { return string == "$null" ? nil : string }
        guard let dict = value as? [String: Any] else { return value }
        if let keys = dict["NS.keys"] as? [Any], let values = dict["NS.objects"] as? [Any] {
            var out: [String: Any] = [:]
            for (k, v) in zip(keys, values) {
                guard let key = resolve(k, objects, depth: depth + 1) as? String,
                      let resolved = resolve(v, objects, depth: depth + 1) else { continue }
                out[key] = resolved
            }
            return out
        }
        if let values = dict["NS.objects"] as? [Any] {
            return values.compactMap { resolve($0, objects, depth: depth + 1) }
        }
        if let time = dict["NS.time"] as? Double { return Date(timeIntervalSinceReferenceDate: time) }
        if let string = dict["NS.string"] as? String { return string }
        if let bytes = dict["NS.bytes"] as? Data { return String(data: bytes, encoding: .utf8) }
        if let data = dict["NS.data"] as? Data { return data }
        // Any other object: its fields by name.
        var out: [String: Any] = [:]
        for (key, field) in dict where key != "$class" {
            if let resolved = resolve(field, objects, depth: depth + 1) { out[key] = resolved }
        }
        return out
    }

    /// The object number inside an archive reference (CFKeyedArchiverUID),
    /// which Foundation has no public way to read: from its description,
    /// "<CFKeyedArchiverUID 0x… [0x…]>{value = 12}".
    private static func uid(_ value: Any) -> Int? {
        if value is String || value is [String: Any] || value is [Any] || value is NSNumber
            || value is Data || value is Date { return nil }
        let text = String(describing: value as AnyObject)
        guard text.contains("KeyedArchiverUID"), let range = text.range(of: "value = ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}

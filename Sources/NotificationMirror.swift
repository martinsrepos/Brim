import AppKit
import SQLite3
import os
import Observation

/// Mirrors macOS Notification Center into the notch.
///
/// macOS keeps every delivered notification in a local SQLite database owned by
/// the `usernoted` daemon. Since Sequoia it lives in a TCC-protected group
/// container, so reading it needs Full Disk Access (the same approach Notchy uses).
/// The format is undocumented: a major macOS update can change it.
///
/// Everything here runs on the main actor. Each read is a couple of small,
/// read-only queries, triggered only when the database files change.
@MainActor
final class NotificationMirror {
    enum Status: Equatable {
        case off
        case needsAccess   // Full Disk Access not granted yet
        case running
        case unreadable    // opened, but the format isn't what we expect
    }

    private(set) var status: Status = .off {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    /// Called for each notification. `isNew` is false for ones that were already
    /// there when the mirror started (they go to history without a banner).
    private let onAlert: @MainActor (NotchAlert, _ isNew: Bool) -> Void
    var onStatusChange: (@MainActor (Status) -> Void)?

    private var timer: Timer?
    /// Watches the database files: macOS tells Brim the instant usernoted
    /// writes, so a notification is read within milliseconds instead of
    /// waiting for the next check. The timer stays as a backup.
    private var watchers: [DispatchSourceFileSystemObject] = []
    /// Every notification seen so far, by its record's UUID (or row + content
    /// when there's no UUID), with a fingerprint of its content.
    ///
    /// Not "rows above the last row number": SQLite reuses the newest row
    /// number when that row is deleted, and apps like WhatsApp delete a chat's
    /// notification and post a new one for each message. Watching row numbers
    /// missed exactly those.
    private var seen: [String: Int] = [:]
    /// The delivery date last seen for each notification, so one updated with a
    /// newer message (Messages reuses a notification for a conversation) shows again.
    private var seenDates: [String: Date] = [:]
    private var lastStamp = ""
    private var apps: [String: AppInfo] = [:]
    private let log = Logger(subsystem: "app.brim.mac", category: "mirror")

    private struct AppInfo {
        var name: String
        var icon: NSImage?
    }

    private struct Row {
        var id: Int64
        var data: Data
        /// Bundle ID from the `app` table, used when the record itself doesn't carry one.
        var appIdentifier: String?
        /// The record's own UUID, when this macOS version stores one.
        var uuid: String?

        var key: String { uuid ?? "\(id)-\(fingerprint)" }

        /// A hash of the whole record (Data's own hash only covers the start).
        var fingerprint: Int {
            var hasher = Hasher()
            data.withUnsafeBytes { hasher.combine(bytes: $0) }
            return hasher.finalize()
        }
    }

    /// How many of the newest records each check looks at.
    private static let window: Int32 = 40

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2", isDirectory: true)
    static var databasePath: String { directory.appendingPathComponent("db").path }

    /// Opens the right pane of System Settings.
    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    init(onAlert: @escaping @MainActor (NotchAlert, _ isNew: Bool) -> Void) {
        self.onAlert = onAlert
    }

    // MARK: - Lifecycle

    func start() {
        guard status == .off else { return }
        if Self.hasAccess {
            prime()
        } else {
            status = .needsAccess
            schedule(every: 2)  // notice the moment access is granted
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        unwatch()
        status = .off
    }

    private func watch() {
        unwatch()
        for name in ["db", "db-wal"] {
            let path = Self.directory.appendingPathComponent(name).path
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
            // The handler holds the source until `unwatch()` cancels it.
            source.setEventHandler { [weak self] in
                let events = source.data
                MainActor.assumeIsolated { self?.fileChanged(events) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func unwatch() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
    }

    private func fileChanged(_ events: DispatchSource.FileSystemEvent) {
        guard status == .running else { return }
        // SQLite replaced the file (e.g. a fresh write-ahead log): watch the new one.
        if events.contains(.delete) || events.contains(.rename) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated { self?.watch() }
            }
        }
        checkForChanges()
    }

    /// Without Full Disk Access the kernel refuses to open the file at all.
    static var hasAccess: Bool {
        let fd = open(databasePath, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    private func schedule(every interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        switch status {
        case .needsAccess, .unreadable:
            if Self.hasAccess { prime() }
        case .running:
            checkForChanges()
        case .off:
            break
        }
    }

    // MARK: - Reading

    /// Loads the most recent notifications into history and remembers what's there.
    private func prime() {
        guard let recent = withDatabase({ fetch($0, limit: Self.window) }) else {
            status = Self.hasAccess ? .unreadable : .needsAccess
            NotificationLog.write("Can't read the notification database (\(status == .needsAccess ? "no Full Disk Access" : "unexpected format"))")
            schedule(every: status == .unreadable ? 30 : 2)
            return
        }
        seen = Dictionary(recent.map { ($0.key, $0.fingerprint) }, uniquingKeysWith: { a, _ in a })
        for row in recent { if let date = Self.deliveryDate(of: row) { seenDates[row.key] = date } }
        for row in recent.suffix(12) {
            if let alert = makeAlert(from: row) { onAlert(alert, false) }
        }
        let keyKind = recent.first?.uuid != nil ? "UUID" : "row + content"
        NotificationLog.write("Started: \(recent.count) recent notifications in the database, tracked by \(keyKind)")
        lastStamp = Self.stamp()
        status = .running
        watch()
        schedule(every: 2)  // backup; the file watchers are what notice changes
        NotificationLog.write("Watching the database for changes (\(watchers.count) files)")
    }

    /// Cheap check first (file size and date); only query when something changed.
    private func checkForChanges() {
        Diag.count("notifications.check")
        let stamp = Self.stamp()
        guard stamp != lastStamp else { return }
        lastStamp = stamp
        Diag.count("notifications.query")

        guard let rows = withDatabase({ fetch($0, limit: Self.window) }) else {
            if !Self.hasAccess {
                status = .needsAccess
                NotificationLog.write("Lost Full Disk Access")
                schedule(every: 2)
            }
            return
        }
        for row in rows {
            let fingerprint = row.fingerprint
            if let known = seen[row.key] {
                // Same notification, new content: an app updated it in place.
                if known != fingerprint {
                    seen[row.key] = fingerprint
                    let alert = makeAlert(from: row)
                    // A newer message in the same notification (Messages does this
                    // for a conversation) is news: show it. Anything else that
                    // changes in place (progress, edits) isn't shown again.
                    if let alert, let previous = seenDates[row.key],
                       alert.date.timeIntervalSince(previous) > 1, abs(alert.date.timeIntervalSinceNow) < (Self.isMessages(alert.bundleID) ? 600 : 120) {
                        seenDates[row.key] = alert.date
                        NotificationLog.write("UPDATED  row \(row.id)  \(alert.bundleID ?? "?")  \(NotificationLog.short(alert.title))  -> banner (a newer message in the same notification)")
                        onAlert(alert, true)
                    } else {
                        NotificationLog.write("UPDATED  row \(row.id)  \(alert?.bundleID ?? row.appIdentifier ?? "?")  \(NotificationLog.short(alert?.title))  (not shown again)")
                    }
                }
                continue
            }
            seen[row.key] = fingerprint
            guard let alert = makeAlert(from: row) else {
                NotificationLog.write("SKIPPED  row \(row.id)  \(row.appIdentifier ?? "?")  couldn't read its content")
                continue
            }
            // Something delivered long ago (e.g. while asleep) goes to history quietly.
            let age = abs(alert.date.timeIntervalSinceNow)
            // iMessage stamps a message with when it was sent, and it can reach
            // a Mac a few minutes later, so Messages gets a longer window.
            let isNew = age < (Self.isMessages(alert.bundleID) ? 600 : 120)
            let outcome = isNew ? String(format: "-> banner (%.1fs after delivery)", age)
                                : "-> history only (delivered \(Int(age))s ago)"
            seenDates[row.key] = alert.date
            NotificationLog.write("NEW      row \(row.id)  \(alert.bundleID ?? "?")  \(NotificationLog.short(alert.title))  message: \(alert.body?.count ?? 0) chars  \(outcome)")
            onAlert(alert, isNew)
        }
        // Keep memory small: forget records that have scrolled far out of view.
        if seen.count > 2_000 {
            let current = Set(rows.map(\.key))
            seen = seen.filter { current.contains($0.key) }
            seenDates = seenDates.filter { current.contains($0.key) }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) -> T?) -> T? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(Self.databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            log.error("Couldn't open the notification database")
            return nil
        }
        sqlite3_busy_timeout(handle, 250)
        return body(handle)
    }

    /// The newest records, oldest first. Joins the `app` table for the sender's
    /// bundle ID and reads the record's UUID; if this macOS version lays the
    /// tables out differently, falls back step by step to `rowid` and `data`,
    /// the two things least likely to change.
    private func fetch(_ db: OpaquePointer, limit: Int32) -> [Row]? {
        let queries: [(sql: String, identifier: Bool, uuid: Bool)] = [
            ("""
             SELECT r.rowid, r.data, a.identifier, r.uuid FROM record r
             LEFT JOIN app a ON a.app_id = r.app_id
             ORDER BY r.rowid DESC LIMIT ?1
             """, true, true),
            ("""
             SELECT r.rowid, r.data, a.identifier FROM record r
             LEFT JOIN app a ON a.app_id = r.app_id
             ORDER BY r.rowid DESC LIMIT ?1
             """, true, false),
            ("SELECT rowid, data FROM record ORDER BY rowid DESC LIMIT ?1", false, false),
        ]

        var statement: OpaquePointer?
        var chosen: (sql: String, identifier: Bool, uuid: Bool)?
        for query in queries where sqlite3_prepare_v2(db, query.sql, -1, &statement, nil) == SQLITE_OK {
            chosen = query
            break
        }
        guard let chosen, let statement else {
            log.error("Notification query failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, limit)

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard count > 0 else { continue }
            var identifier: String?
            if chosen.identifier, let text = sqlite3_column_text(statement, 2) {
                identifier = String(cString: text)
            }
            var uuid: String?
            if chosen.uuid, let blob = sqlite3_column_blob(statement, 3) {
                let length = Int(sqlite3_column_bytes(statement, 3))
                if length > 0 {
                    uuid = Data(bytes: blob, count: length).map { String(format: "%02x", $0) }.joined()
                }
            }
            rows.append(Row(id: id, data: Data(bytes: bytes, count: count), appIdentifier: identifier, uuid: uuid))
        }
        return Array(rows.reversed())
    }

    private static func isMessages(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return id == "com.apple.mobilesms" || id == "com.apple.ichat"
    }

    /// Just the delivery date of a record, without building an alert.
    private static func deliveryDate(of row: Row) -> Date? {
        guard let plist = try? PropertyListSerialization.propertyList(from: row.data, format: nil) as? [String: Any] else { return nil }
        if let seconds = plist["date"] as? Double { return Date(timeIntervalSinceReferenceDate: seconds) }
        return plist["date"] as? Date
    }

    /// Each record's `data` is a binary property list:
    /// `app` = bundle ID, `date` = seconds since 2001, `req` = { titl, subt, body, ... }.
    private func makeAlert(from row: Row) -> NotchAlert? {
        guard let plist = try? PropertyListSerialization.propertyList(from: row.data, format: nil) as? [String: Any] else {
            return nil
        }
        let request = plist["req"] as? [String: Any] ?? [:]
        let bundleID = nonEmpty(plist["app"]) ?? row.appIdentifier ?? ""
        let app = appInfo(for: bundleID)

        let title = nonEmpty(request["titl"]) ?? app.name
        let subtitle = nonEmpty(request["subt"])
        let body = nonEmpty(request["body"])
        guard subtitle != nil || body != nil || !title.isEmpty else { return nil }

        var date = Date()
        if let seconds = plist["date"] as? Double {
            date = Date(timeIntervalSinceReferenceDate: seconds)
        } else if let value = plist["date"] as? Date {
            date = value
        }
        if abs(date.timeIntervalSinceNow) > 86_400 * 365 { date = Date() }  // sanity check

        return NotchAlert(symbol: "app.badge.fill", tint: .accentColor,
                          title: title, subtitle: subtitle, body: body,
                          appIcon: app.icon, appName: app.name,
                          bundleID: bundleID.isEmpty ? nil : bundleID,
                          duration: 5, date: date)
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// The sending app's name and icon. Safari's website notifications (bundle
    /// IDs like `web.com.example`) get Safari's icon and the site's name.
    private func appInfo(for bundleID: String) -> AppInfo {
        if let cached = apps[bundleID] { return cached }
        let fallbackName = bundleID.split(separator: ".").last.map { String($0).capitalized } ?? "Notification"
        var info = AppInfo(name: fallbackName, icon: nil)

        if bundleID.lowercased().hasPrefix("web."),
           let safari = AppLocator.url(for: "com.apple.Safari") {
            let site = bundleID.dropFirst(4).split(separator: ".").reversed().joined(separator: ".")
            info = AppInfo(name: site.isEmpty ? "Safari" : site, icon: NSWorkspace.shared.icon(forFile: safari.path))
        } else if let url = AppLocator.url(for: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            info.name = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            info.icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        apps[bundleID] = info
        return info
    }

    /// Size + modification date of the database and its write-ahead log.
    private static func stamp() -> String {
        ["db", "db-wal"].map { name -> String in
            let path = directory.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return "\(modified):\(size)"
        }
        .joined(separator: "|")
    }
}

/// The Focus that's on (Do Not Disturb, Work, Sleep...) and which apps it
/// still lets through, read from the files macOS keeps them in
/// (~/Library/DoNotDisturb/DB; Brim's Full Disk Access covers them).
///
/// The format is undocumented, so this reads defensively: if it can't tell,
/// it treats Focus as off and notifications show as usual. Changes are noted
/// in the Notification Log.
@MainActor
@Observable
final class FocusMonitor {
    private(set) var isActive = false
    private(set) var name: String?
    /// Lowercased bundle IDs the Focus allows.
    private(set) var allowedApps: Set<String> = []
    /// The Focus lets some people through. Those people reach you in Messages,
    /// FaceTime and calls, and Brim can't tell who sent a notification, so those
    /// apps get through too (macOS itself still decides what it shows).
    private(set) var allowsPeople = false
    private static let peopleApps: Set<String> = ["com.apple.mobilesms", "com.apple.facetime", "com.apple.telephonyutilities", "com.apple.ichat"]

    @ObservationIgnored private var timer: Timer?

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !QuietState.shared.isDark else { return }
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Whether a notification from this app should still pop up as a banner.
    func allows(_ bundleID: String?) -> Bool {
        guard isActive else { return true }
        guard let id = bundleID?.lowercased() else { return false }
        if allowsPeople, Self.peopleApps.contains(id) { return true }
        return allowedApps.contains(id) || allowedApps.contains { id.hasPrefix($0 + ".") }
    }

    private func refresh() {
        let modes = Self.activeModeIdentifiers()
        var newName: String?
        var allowed: Set<String> = []
        var people = false
        if let mode = modes.first {
            let details = Self.modeDetails(for: mode)
            newName = details.name ?? "Focus"
            allowed = details.allowed
            people = details.people
        }
        let active = !modes.isEmpty
        guard active != isActive || newName != name || allowed != allowedApps || people != allowsPeople else { return }
        isActive = active
        name = newName
        allowedApps = allowed
        allowsPeople = people
        NotificationLog.write(active
            ? "Focus on: \(newName ?? "Focus") (\(allowed.count) apps allowed through\(people ? ", and some people" : ""))"
            : "Focus off")
    }

    private static func json(_ file: String) -> Any? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Mode IDs of the Focus assertions that are in force right now.
    private static func activeModeIdentifiers() -> [String] {
        guard let root = json("Assertions.json") else { return [] }
        var records: [Any] = []
        collect(in: root) { key, value in
            if key == "storeAssertionRecords", let list = value as? [Any] { records.append(contentsOf: list) }
        }
        var modes: [String] = []
        for record in records {
            collect(in: record) { key, value in
                if key == "assertionDetailsModeIdentifier", let mode = value as? String { modes.append(mode) }
            }
        }
        return modes
    }

    /// The Focus's name, and the apps it allows (bundle IDs found anywhere
    /// under a key that mentions "allow").
    private static func modeDetails(for mode: String) -> (name: String?, allowed: Set<String>, people: Bool) {
        guard let root = json("ModeConfigurations.json") else { return (nil, [], false) }
        var config: Any?
        collect(in: root) { key, value in
            if key == "modeConfigurations", let all = value as? [String: Any], let match = all[mode] {
                config = match
            }
        }
        guard let config else { return (nil, [], false) }
        var name: String?
        collect(in: config) { key, value in
            if name == nil, key == "name", let text = value as? String { name = text }
        }
        var allowed: Set<String> = []
        collect(in: config) { key, value in
            guard key.lowercased().contains("allow") else { return }
            collect(in: value) { _, inner in
                if let text = inner as? String, looksLikeBundleID(text) { allowed.insert(text.lowercased()) }
            }
            if let text = value as? String, looksLikeBundleID(text) { allowed.insert(text.lowercased()) }
            if let list = value as? [Any] {
                for item in list where (item as? String).map(looksLikeBundleID) == true {
                    allowed.insert((item as! String).lowercased())
                }
            }
        }
        // People allowed through: a contact, a phone number or an address
        // anywhere under an "allow" key, or a non-empty list under a key about people.
        var people = false
        collect(in: config) { key, value in
            let k = key.lowercased()
            guard k.contains("allow") || k.contains("contact") || k.contains("people") || k.contains("person") else { return }
            if (k.contains("contact") || k.contains("people") || k.contains("person")),
               let list = value as? [Any], !list.isEmpty { people = true }
            collect(in: value) { _, inner in
                if let text = inner as? String, looksLikePerson(text) { people = true }
            }
        }
        return (name, allowed, people)
    }

    private static func looksLikePerson(_ text: String) -> Bool {
        text.contains("@") || text.range(of: #"^\+?[0-9 ()-]{6,}$"#, options: .regularExpression) != nil
            || text.hasSuffix(":ABPerson")
    }

    private static func looksLikeBundleID(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    /// Visits every key/value pair in nested dictionaries and arrays.
    private static func collect(in value: Any, _ visit: (String, Any) -> Void) {
        if let dict = value as? [String: Any] {
            for (key, inner) in dict {
                visit(key, inner)
                collect(in: inner, visit)
            }
        } else if let list = value as? [Any] {
            for inner in list { collect(in: inner, visit) }
        }
    }
}

/// Finds an app from the bundle ID stored with a notification.
///
/// Notification Center sometimes stores IDs in a different letter case than the
/// app declares (`com.apple.safari`), or a more specific ID than the app itself
/// (`com.apple.Safari.WebApp.1234` for a web app added to the Dock). Launch
/// Services' exact lookup misses those, so this falls back to an index of the
/// usual app folders, matched case-insensitively and by parent ID.
@MainActor
enum AppLocator {
    private static var index: [String: URL]?

    static func url(for bundleID: String) -> URL? {
        guard !bundleID.isEmpty else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }

        let apps = loadIndex()
        var parts = bundleID.lowercased().split(separator: ".")
        while parts.count >= 2 {
            if let url = apps[parts.joined(separator: ".")] { return url }
            parts.removeLast()
        }
        return nil
    }

    /// Built once, on first miss: a few hundred bundle reads.
    private static func loadIndex() -> [String: URL] {
        if let index { return index }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",  // where Safari lives now
            "\(home)/Applications", "\(home)/Applications/Chrome Apps.localized",
        ]
        var found: [String: URL] = [:]
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" {
                guard let id = Bundle(url: url)?.bundleIdentifier?.lowercased(), found[id] == nil else { continue }
                found[id] = url
            }
        }
        index = found
        return found
    }
}

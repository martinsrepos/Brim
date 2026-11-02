import AppKit
import Foundation
import Observation
import SQLite3
import SwiftUI

/// Other apps' Live Activities, including the ones your iPhone sends to the
/// Mac (macOS 26 and later show them in the menu bar).
///
/// macOS keeps them in a small SQLite database, readable with the Full Disk
/// Access Brim already has for notifications. Each activity carries the app,
/// Apple's relevance score, a stale date, an end date, and the app's own
/// data as JSON (packed in base64). The format is private: if a macOS update
/// changes it, this simply finds nothing and Brim carries on without it.
///
/// Read-only, on this Mac only.
@MainActor
@Observable
final class LiveActivityMonitor {
    /// The activities going on now, most relevant first.
    private(set) var items: [ExternalActivity] = []

    private(set) var isEnabled: Bool
    private(set) var bannersEnabled: Bool

    /// A banner for an update that matters (a goal, the order at the door).
    @ObservationIgnored var onAlert: ((NotchAlert) -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastStamp = ""
    @ObservationIgnored private var primed = false
    /// What each activity showed last time, to notice what changed.
    @ObservationIgnored private var previous: [String: ExternalActivity.Display] = [:]
    @ObservationIgnored private var alerted: Set<String> = []
    /// The ones you hid: they stay hidden until they end. Kept across
    /// restarts, and forgotten once macOS drops them.
    @ObservationIgnored private var dismissed: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "liveActivitiesDismissed") ?? [])

    static let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.liveactivitiesd/liveactivitiesd.sql").path

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "liveActivitiesEnabled") as? Bool ?? true
        bannersEnabled = defaults.object(forKey: "liveActivityBanners") as? Bool ?? true
    }

    /// macOS has a Live Activities database at all (macOS 26 and later).
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: databasePath) }

    func start() {
        guard isEnabled else { return }
        timer?.invalidate()
        // A cheap check (file size and date) every 2 seconds; the database is
        // only read when it changed. Freshness is checked on the same beat.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        items = []
        lastStamp = ""
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: "liveActivitiesEnabled")
        if on { start() } else { stop() }
    }

    func setBannersEnabled(_ on: Bool) {
        bannersEnabled = on
        UserDefaults.standard.set(on, forKey: "liveActivityBanners")
    }

    /// Hides one in Brim (macOS still shows it in the menu bar).
    func dismiss(_ id: String) {
        dismissed.insert(id)
        UserDefaults.standard.set(Array(dismissed), forKey: "liveActivitiesDismissed")
        items.removeAll { $0.id == id }
    }

    func item(_ id: String?) -> ExternalActivity? {
        guard let id else { return items.first }
        return items.first { $0.id == id }
    }

    // MARK: - Reading

    private func poll() {
        guard !QuietState.shared.isDark else { return }
        Diag.count("liveActivities.check")
        let stamp = Self.stamp()
        if stamp != lastStamp {
            lastStamp = stamp
            read()
        } else {
            refreshTimes()
        }
    }

    /// Stale ones dim and ended ones go, on time, even without a database change.
    private func refreshTimes() {
        let now = Date()
        var changed = false
        var list = items.filter { activity in
            if let end = activity.endDate, end <= now { changed = true; return false }
            return true
        }
        for index in list.indices {
            let stale = list[index].staleDate.map { $0 <= now } ?? false
            if list[index].isStale != stale { list[index].isStale = stale; changed = true }
        }
        if changed { withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { items = list } }
    }

    private func read() {
        Diag.count("liveActivities.read")
        guard let rows = Self.fetch() else { return }
        let now = Date()
        var list: [ExternalActivity] = []
        for row in rows {
            guard var activity = Self.parse(row) else { continue }
            if let end = activity.endDate, end <= now { continue }
            activity.isStale = activity.staleDate.map { $0 <= now } ?? false
            list.append(activity)
        }
        list.sort { $0.relevance != $1.relevance ? $0.relevance > $1.relevance : $0.started > $1.started }
        // Forget hidden ones macOS no longer has; leave out the rest.
        let present = Set(rows.map(\.id))
        if !dismissed.isSubset(of: present) {
            dismissed.formIntersection(present)
            UserDefaults.standard.set(Array(dismissed), forKey: "liveActivitiesDismissed")
        }
        list.removeAll { dismissed.contains($0.id) }

        if primed { announce(list) }
        primed = true
        previous = Dictionary(list.map { ($0.id, $0.display) }, uniquingKeysWith: { a, _ in a })

        if list != items {
            if list.map(\.id) != items.map(\.id) {
                Diag.event("Live Activities: \(list.count) (\(Set(list.map(\.bundleID)).sorted().joined(separator: ", ")))")
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { items = list }
        }
    }

    /// Banners for updates that matter: ones the app marked as an alert, and
    /// for matches, a goal or a red card. Ordinary updates stay quiet.
    private func announce(_ list: [ExternalActivity]) {
        guard bannersEnabled else { return }
        for activity in list {
            if let alert = activity.alert, alerted.insert("\(activity.id)|\(alert.key)").inserted {
                post(activity, title: alert.title, body: alert.body)
                continue
            }
            guard case .match(let now) = activity.display,
                  case .match(let before)? = previous[activity.id] else { continue }
            let minute = now.minute.map { "\($0)' · " } ?? ""
            let line = "\(now.home) \(now.homeScore) – \(now.awayScore) \(now.away)"
            if now.homeScore + now.awayScore > before.homeScore + before.awayScore {
                post(activity, title: "Goal! \(line)", body: minute + (now.competition ?? activity.appName))
            } else if now.homeRed + now.awayRed > before.homeRed + before.awayRed {
                let team = now.homeRed > before.homeRed ? now.home : now.away
                post(activity, title: "Red card, \(team)", body: minute + line)
            }
        }
    }

    private func post(_ activity: ExternalActivity, title: String, body: String?) {
        Diag.count("liveActivities.banner")
        onAlert?(NotchAlert(symbol: "dot.radiowaves.left.and.right", tint: .green, title: title, body: body,
                            appIcon: activity.icon, appName: activity.appName, duration: 6,
                            action: .openLiveActivity(activity.id)))
    }

    // MARK: - Opening

    /// The app itself when it's on this Mac; otherwise iPhone Mirroring,
    /// like clicking the activity in the menu bar.
    func open(_ id: String) {
        guard let activity = items.first(where: { $0.id == id }) else { return }
        if let url = AppLocator.url(for: activity.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else if let mirroring = Self.iPhoneMirroring {
            NSWorkspace.shared.openApplication(at: mirroring, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    private static var iPhoneMirroring: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenContinuity") { return url }
        let path = "/System/Applications/iPhone Mirroring.app"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: - The database

    struct Row {
        let id: String
        let device: String?
        let created: Double
        let request: Data
        let requester: String
        let payload: Data
        let dismissal: Double?
        let appName: String?
    }

    private static func stamp() -> String {
        ["", "-wal"].map { suffix -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath + suffix)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return "\(modified):\(size)"
        }
        .joined(separator: "|")
    }

    private static func fetch() -> [Row]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        sqlite3_busy_timeout(db, 250)
        // localizedAppName came in a later version: fall back without it.
        let queries = [
            "SELECT activityIdentifier, deviceIdentifier, createdDate, request, requester, payload, dismissalDate, localizedAppName FROM Activities",
            "SELECT activityIdentifier, deviceIdentifier, createdDate, request, requester, payload, dismissalDate, NULL FROM Activities",
        ]
        var statement: OpaquePointer?
        guard queries.contains(where: { sqlite3_prepare_v2(db, $0, -1, &statement, nil) == SQLITE_OK }), let statement else {
            Diag.event("Live Activities: unexpected database layout")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        func text(_ i: Int32) -> String? {
            sqlite3_column_text(statement, i).map { String(cString: $0) }
        }
        func blob(_ i: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, i) else {
                return text(i).flatMap { $0.data(using: .utf8) } ?? Data()
            }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, i)))
        }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(0), let requester = text(4) else { continue }
            rows.append(Row(id: id, device: text(1), created: sqlite3_column_double(statement, 2),
                            request: blob(3), requester: requester, payload: blob(5),
                            dismissal: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
                            appName: text(7)))
        }
        return rows
    }

    // MARK: - Making sense of an activity

    private static func parse(_ row: Row) -> ExternalActivity? {
        guard let payload = (try? JSONSerialization.jsonObject(with: row.payload)) as? [String: Any] else { return nil }
        let request = (try? JSONSerialization.jsonObject(with: row.request)) as? [String: Any] ?? [:]
        let content = payload["content"] as? [String: Any]
        let state = embedded(content?["contentState"]) ?? embedded(payload["contentState"])
        let attributes = embedded(request["attributesData"])

        let appName = row.appName ?? AppLocator.url(for: row.requester)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? row.requester.split(separator: ".").last.map(String.init) ?? "App"
        let relevance = number(content?["relevanceScore"]) ?? 0
        let stale = number(content?["staleDate"]).flatMap(date) ?? number(payload["staleDate"]).flatMap(date)

        var activity = ExternalActivity(
            id: row.id, bundleID: row.requester, appName: appName,
            fromiPhone: row.device != nil && AppLocator.url(for: row.requester) == nil,
            started: date(row.created) ?? Date(),
            relevance: relevance, staleDate: stale, endDate: row.dismissal.flatMap(date),
            display: display(state: state, attributes: attributes, appName: appName))
        activity.alert = alert(in: payload)
        return activity
    }

    /// The app's own data: JSON, usually packed in base64.
    private static func embedded(_ value: Any?) -> Any? {
        if let object = value as? [String: Any] { return object }
        guard let string = value as? String else { return nil }
        if let data = Data(base64Encoded: string), let json = try? JSONSerialization.jsonObject(with: data) { return json }
        if let data = string.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { return json }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// A date in whichever form it comes: seconds since 2001 (Apple's
    /// reference date), since 1970, or milliseconds.
    private static func date(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        if value > 1e12 { return Date(timeIntervalSince1970: value / 1000) }
        if value > 1.2e9 { return Date(timeIntervalSince1970: value) }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    /// Every value in the JSON with the name of its key (and its parent's).
    private static func leaves(_ value: Any?, key: String = "", parent: String = "") -> [(key: String, parent: String, value: Any)] {
        if let object = value as? [String: Any] {
            return object.keys.sorted().flatMap { leaves(object[$0], key: $0, parent: key) }
        }
        if let array = value as? [Any] {
            return array.flatMap { leaves($0, key: key, parent: parent) }
        }
        guard let value else { return [] }
        return [(key, parent, value)]
    }

    private static func matches(_ key: String, _ pattern: String) -> Bool {
        key.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Short readable text, not an ID, a link or a code.
    private static func isReadable(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard (1...60).contains(t.count), !t.contains("://") else { return false }
        if t.range(of: "^[0-9A-Fa-f-]{16,}$", options: .regularExpression) != nil { return false }
        if t.count > 24 && !t.contains(" ") { return false }
        return true
    }

    private static func display(state: Any?, attributes: Any?, appName: String) -> ExternalActivity.Display {
        if let match = match(state: state, attributes: attributes) { return .match(match) }
        return .general(general(state: state, attributes: attributes, appName: appName))
    }

    /// Sports: two scores in the live data and two teams in the fixed data.
    private static func match(state: Any?, attributes: Any?) -> ExternalActivity.Match? {
        let live = leaves(state)
        var scores = live.filter { matches($0.key, "score") }.compactMap { leaf in number(leaf.value).map { (leaf.key, Int($0)) } }
        guard scores.count >= 2 else { return nil }
        // Home first: "home" before "away", otherwise by name (score1, score2).
        scores.sort { a, b in
            let ah = matches(a.0, "home"), bh = matches(b.0, "home")
            return ah != bh ? ah : a.0 < b.0
        }
        let fixed = leaves(attributes)
        let names = fixed.filter { matches($0.parent, "^(comps|competitors|teams|participants|sides)$") && matches($0.key, "^(n|name|teamname|shortname|title|displayname)$") }
            .compactMap { $0.value as? String }
        var home = names.first, away = names.count > 1 ? names[1] : nil
        if home == nil || away == nil {
            home = fixed.first { matches($0.key, "^home(team)?(name)?$") }?.value as? String
            away = fixed.first { matches($0.key, "^away(team)?(name)?$") }?.value as? String
        }
        guard let home, let away else { return nil }
        let competition = fixed.first { matches($0.parent, "^(comp|competition|league|tournament)$") && matches($0.key, "^(n|name|title)$") }?.value as? String
            ?? fixed.first { matches($0.key, "^(competition|league|tournament)(name)?$") }?.value as? String
        let minute = live.first { matches($0.key, "(livetime|minute|gametime|matchtime|clock|elapsed)") }.flatMap { number($0.value) }.map { Int($0) }
        let reds = live.filter { matches($0.key, "^(rc|redcards?)[_-]?(1|2|home|away)$") }
            .sorted { matches($0.key, "(1|home)$") && !matches($1.key, "(1|home)$") }
            .compactMap { number($0.value).map { Int($0) } }
        return ExternalActivity.Match(home: home, away: away, homeScore: scores[0].1, awayScore: scores[1].1,
                                      minute: minute.flatMap { $0 > 0 ? $0 : nil }, competition: competition,
                                      homeRed: reds.first ?? 0, awayRed: reds.count > 1 ? reds[1] : 0)
    }

    /// Any other app: its main line, a second line, and the value that changes.
    private static func general(state: Any?, attributes: Any?, appName: String) -> ExternalActivity.General {
        let live = leaves(state), fixed = leaves(attributes)
        let textPattern = "(title|status|headline|message|text|label|name|description|stage|step|state)"
        let liveTexts = live.filter { ($0.value as? String).map(isReadable) ?? false }
        let fixedTexts = fixed.filter { ($0.value as? String).map(isReadable) ?? false }
        let title = (liveTexts.first { matches($0.key, textPattern) } ?? liveTexts.first ?? fixedTexts.first { matches($0.key, textPattern) } ?? fixedTexts.first)?.value as? String
        let subtitle = (fixedTexts + liveTexts).compactMap { $0.value as? String }.first { $0 != title }

        var value: String?
        var progress: Double?
        for leaf in live {
            guard let n = number(leaf.value) else { continue }
            if matches(leaf.key, "(progress|percent|fraction|completion)") {
                progress = n > 1 ? n / 100 : n
                value = "\(Int((progress ?? 0) * 100))%"
                break
            }
            if matches(leaf.key, "(eta|arrival|until|end|deadline|due)"), let d = date(n), d > Date(), d.timeIntervalSinceNow < 86_400 {
                value = "\(max(1, Int(d.timeIntervalSinceNow / 60))) min"
                break
            }
            if matches(leaf.key, "(minutes|mins|remaining)") {
                value = "\(Int(n)) min"
                break
            }
        }
        if value == nil {
            value = liveTexts.first { matches($0.key, "(eta|time|remaining|count|distance)") }?.value as? String
        }
        return ExternalActivity.General(title: title ?? appName, subtitle: subtitle, value: value, progress: progress)
    }

    /// An update the app marked as an alert: any object under a key with
    /// "alert" in it that has a title or a body.
    private static func alert(in payload: [String: Any]) -> ExternalActivity.Alert? {
        func search(_ value: Any?, under key: String) -> [String: Any]? {
            if let object = value as? [String: Any] {
                if matches(key, "alert"), object["title"] != nil || object["body"] != nil { return object }
                for (k, v) in object { if let found = search(v, under: k) { return found } }
            }
            return nil
        }
        guard let found = search(payload, under: "") else { return nil }
        func string(_ v: Any?) -> String? {
            if let s = v as? String { return s }
            if let d = v as? [String: Any] { return (d["key"] ?? d["localizationKey"] ?? d["value"]) as? String }
            return nil
        }
        guard let title = string(found["title"]) ?? string(found["body"]) else { return nil }
        let body = string(found["title"]) != nil ? string(found["body"]) : nil
        let stamp = number(payload["timestamp"]).map { String($0) } ?? title
        return ExternalActivity.Alert(key: stamp, title: title, body: body)
    }
}

/// One Live Activity from another app, ready to show.
struct ExternalActivity: Identifiable, Equatable {
    let id: String
    let bundleID: String
    let appName: String
    /// Sent from the iPhone, for an app this Mac doesn't have.
    let fromiPhone: Bool
    let started: Date
    var relevance: Double
    var staleDate: Date?
    var endDate: Date?
    var display: Display
    var alert: Alert? = nil
    /// Past its stale date: the app stopped sending updates.
    var isStale = false

    enum Display: Equatable {
        case match(Match)
        case general(General)
    }

    struct Match: Equatable {
        var home: String
        var away: String
        var homeScore: Int
        var awayScore: Int
        var minute: Int?
        var competition: String?
        var homeRed = 0
        var awayRed = 0
    }

    struct General: Equatable {
        var title: String
        var subtitle: String?
        var value: String?
        var progress: Double?
    }

    struct Alert: Equatable {
        let key: String
        let title: String
        let body: String?
    }

    /// The app's icon when it's on this Mac.
    /// A Mac app's icon (already shaped); otherwise the iPhone's square one.
    @MainActor var iconIsShaped: Bool { AppLocator.url(for: bundleID) != nil }

    @MainActor var icon: NSImage? {
        if let url = AppLocator.url(for: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return IPhoneAppIcons.icon(for: bundleID)
    }

    /// One line for the pill: "Inter 2 – 1 Milan", or the app's main line.
    var title: String {
        switch display {
        case .match(let m): return "\(m.home) \(m.homeScore) – \(m.awayScore) \(m.away)"
        case .general(let g): return g.title
        }
    }

    /// A match that's being played right now (a minute, fresh data).
    var isLiveMatch: Bool {
        guard case .match(let m) = display else { return false }
        return m.minute != nil && !isStale
    }

    /// Shorter titles for a narrow pill: three-letter team codes
    /// ("MON 1 – 1 HOS"), like scoreboards.
    var shorterTitles: [String] {
        guard case .match(let m) = display else { return [] }
        return ["\(Self.code(m.home)) \(m.homeScore) – \(m.awayScore) \(Self.code(m.away))"]
    }

    /// "Montañesa" → "MON", "Real Madrid" → "RMA", "FC Barcelona" → "BAR".
    static func code(_ name: String) -> String {
        let skip: Set<String> = ["fc", "cf", "cd", "ud", "sd", "ac", "as", "ss", "sc", "afc", "club", "the", "de", "la", "el"]
        let words = name.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { !skip.contains($0.lowercased()) }
        guard let first = words.first else { return String(name.prefix(3)).uppercased() }
        let letters = words.count > 1 && first.count <= 4
            ? String(first.prefix(1)) + String(words[1].prefix(2))
            : String(first.prefix(3))
        return letters.uppercased()
    }

    /// The short value: the minute, or the app's changing value.
    var value: String? {
        switch display {
        case .match(let m): return m.minute.map { "\($0)'" }
        case .general(let g): return g.value
        }
    }

    /// For the circle: the score, or the value.
    var short: String? {
        switch display {
        case .match(let m): return "\(m.homeScore)–\(m.awayScore)"
        case .general(let g): return g.value
        }
    }

    /// Around the ring: a match's 90 minutes, or the app's progress.
    var progress: Double? {
        switch display {
        case .match(let m): return m.minute.map { min(1, Double($0) / 90) }
        case .general(let g): return g.progress
        }
    }
}

/// Icons of iPhone apps. macOS keeps a copy of each for the widgets and Live
/// Activities your iPhone shares, in WidgetKit's folder:
/// `group.com.apple.chronod/chronod/icons/…::<iPhone>::<bundle ID>.heic`.
/// Read with Full Disk Access, once per app.
@MainActor
enum IPhoneAppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var missing: [String: Date] = [:]

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.chronod/chronod/icons")

    static func icon(for bundleID: String) -> NSImage? {
        if let image = cache[bundleID] { return image }
        // Not there yet: look again after a minute, not on every redraw.
        if let tried = missing[bundleID], Date().timeIntervalSince(tried) < 60 { return nil }
        let suffix = "::\(bundleID).heic".lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let name = files.first(where: { $0.lowercased().hasSuffix(suffix) }),
              let image = NSImage(contentsOf: folder.appendingPathComponent(name)) else {
            missing[bundleID] = Date()
            return nil
        }
        cache[bundleID] = image
        return image
    }
}

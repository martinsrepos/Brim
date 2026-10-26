import AppKit
import Foundation
import Observation
import Security

/// Looks on GitHub for a newer Brim and, when you say so, installs it.
///
/// The check is one request to GitHub's public API for the latest release. It
/// sends nothing about you (no ID, no settings), only the usual request
/// headers. Installing downloads the release's DMG, makes sure the app inside
/// is signed with the same certificate as the copy that's running (so only the
/// same developer can update it, and macOS keeps your permissions), swaps it
/// in and opens it again.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    nonisolated static let repository = "martinsrepos/Brim"
    nonisolated static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    private nonisolated static let latestAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Automatic checks: at most this often.
    private static let interval: TimeInterval = 24 * 60 * 60

    struct Release: Equatable {
        let version: String
        let page: URL
        let dmg: URL?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        /// The fraction downloaded, when the size is known.
        case downloading(Double?)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The newest release seen, newer than this copy.
    private(set) var update: Release?
    private(set) var lastChecked: Date?
    private(set) var checksAutomatically: Bool

    /// Called when an automatic check finds a version you haven't been told about.
    @ObservationIgnored var onFound: ((Release) -> Void)?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var download: URLSessionDownloadTask?
    @ObservationIgnored private var job: Task<Void, Never>?

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {
        checksAutomatically = defaults.object(forKey: "updatesCheckAutomatically") as? Bool ?? true
        lastChecked = defaults.object(forKey: "updatesLastChecked") as? Date
    }

    var hasUpdate: Bool { update != nil }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// Whether this copy can update itself: it has to be signed with a real
    /// certificate to compare the download against. A copy you built with ad
    /// hoc signing sends you to the download page instead.
    var canInstall: Bool {
        if let signed { return signed }
        let found = Self.leafCertificate(of: Bundle.main.bundleURL) != nil
        signed = found
        return found
    }
    @ObservationIgnored private var signed: Bool?

    // MARK: - Checking

    /// Starts the daily automatic check (if it's on).
    func start() {
        loop?.cancel()
        guard checksAutomatically else { return }
        loop = Task { [weak self] in
            // Not during launch: Brim has enough to do then.
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                if self.isDue { await self.check(userInitiated: false) }
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
            }
        }
    }

    func setChecksAutomatically(_ on: Bool) {
        checksAutomatically = on
        defaults.set(on, forKey: "updatesCheckAutomatically")
        if on { start() } else { loop?.cancel(); loop = nil }
    }

    private var isDue: Bool {
        guard let lastChecked else { return true }
        return Date().timeIntervalSince(lastChecked) >= Self.interval
    }

    /// The Check for Updates button.
    func checkNow() {
        guard !isBusy else { return }
        job = Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        let before = phase
        phase = .checking
        do {
            let release = try await Self.fetchLatest()
            lastChecked = Date()
            defaults.set(lastChecked, forKey: "updatesLastChecked")
            if let release, Self.isVersion(release.version, newerThan: Self.currentVersion) {
                update = release
                phase = .available
                if !userInitiated, defaults.string(forKey: "updatesNotifiedVersion") != release.version {
                    defaults.set(release.version, forKey: "updatesNotifiedVersion")
                    onFound?(release)
                }
            } else {
                update = nil
                phase = .upToDate
            }
        } catch {
            appLog.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            // A failed automatic check stays quiet: it tries again later.
            phase = userInitiated ? .failed(Self.message(for: error)) : (before == .available ? .available : .idle)
        }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
        let tagName: String
        let htmlUrl: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// The latest published release, or nil when the project has none yet.
    private nonisolated static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: latestAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Brim", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.server(0) }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw UpdateError.server(http.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let latest = try decoder.decode(GitHubRelease.self, from: data)
        if latest.draft == true || latest.prerelease == true { return nil }
        let dmg = latest.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadUrl
        let version = latest.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        return Release(version: version, page: latest.htmlUrl, dmg: dmg)
    }

    /// "1.0.10" is newer than "1.0.9"; a missing part counts as 0.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    /// The Update button: download, check, swap in, open again.
    func install() {
        guard let update, !isBusy else { return }
        guard canInstall, let dmg = update.dmg else {
            NSWorkspace.shared.open(update.page)
            return
        }
        job = Task { await install(update, from: dmg) }
    }

    func cancel() {
        download?.cancel()
        download = nil
    }

    func openReleasePage() {
        NSWorkspace.shared.open(update?.page ?? Self.releasesPage)
    }

    private func install(_ release: Release, from url: URL) async {
        let target = Bundle.main.bundleURL
        // Run from the DMG, or from Downloads before macOS moved it (App
        // Translocation): there's nowhere to put the new copy.
        if target.path.hasPrefix("/Volumes/") || target.path.contains("/AppTranslocation/") {
            phase = .failed("Move Brim to your Applications folder first, then update from there.")
            return
        }
        phase = .downloading(nil)
        var mount: URL?
        do {
            let file = try await fetch(url)
            defer { try? FileManager.default.removeItem(at: file) }
            phase = .installing

            let point = FileManager.default.temporaryDirectory
                .appendingPathComponent("Brim-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
            try await Self.run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly",
                                                    "-noautoopen", "-mountpoint", point.path])
            mount = point

            guard let found = try FileManager.default.contentsOfDirectory(at: point, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noApp }

            // Copied next to the current app first (same disk), checked there,
            // then swapped in one move.
            let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: target, create: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(target.lastPathComponent)
            try await Self.run("/usr/bin/ditto", [found.path, staged.path])
            try await Self.run("/usr/bin/hdiutil", ["detach", point.path, "-quiet"])
            mount = nil

            try await Self.verify(staged, release: release)
            _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)

            relaunch(target)
        } catch {
            if let mount {
                _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
            }
            if (error as? URLError)?.code == .cancelled {
                phase = .available
                return
            }
            appLog.error("Update failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(Self.message(for: error))
        }
    }

    /// Downloads the DMG to a temporary file, reporting progress.
    private func fetch(_ url: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brim-update-\(UUID().uuidString).dmg")
        var progress: Task<Void, Never>?
        defer { progress?.cancel(); download = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let location, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continuation.resume(throwing: UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0))
                    return
                }
                // The file is gone once this returns, so it's moved here.
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            download = task
            progress = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let self, case .downloading = self.phase else { return }
                    let known = task.countOfBytesExpectedToReceive > 0
                    self.phase = .downloading(known ? task.progress.fractionCompleted : nil)
                }
            }
            task.resume()
        }
    }

    /// Opens the new copy once this one has quit.
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        do {
            try process.run()
        } catch {
            phase = .failed("Brim was updated. Open it again from your Applications folder.")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Checks

    /// The same app, a newer version, intact, and signed by the same
    /// certificate as this copy.
    private nonisolated static func verify(_ app: URL, release: Release) async throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.notBrim }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard isVersion(version, newerThan: currentVersion) else { throw UpdateError.notNewer }
        do {
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError.signature
        }
        guard let mine = leafCertificate(of: Bundle.main.bundleURL),
              let theirs = leafCertificate(of: app), mine == theirs else { throw UpdateError.signature }
    }

    /// The certificate an app is signed with, or nil when it's unsigned or
    /// signed ad hoc.
    private nonisolated static func leafCertificate(of app: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    /// Runs a command line tool and waits for it, off the main thread.
    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: 0)
                } else {
                    continuation.resume(throwing: UpdateError.tool((tool as NSString).lastPathComponent,
                                                                   finished.terminationStatus))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    enum UpdateError: Error {
        case server(Int)
        case noApp
        case notBrim
        case notNewer
        case signature
        case tool(String, Int32)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? UpdateError {
            switch error {
            case .server(let code) where code == 403:
                return "GitHub is limiting requests from your network right now. Try again in a while."
            case .server:
                return "GitHub didn't answer as expected. Try again in a while."
            case .noApp, .notBrim:
                return "The download doesn't contain Brim. Nothing was changed."
            case .notNewer:
                return "The download isn't newer than this copy. Nothing was changed."
            case .signature:
                return "The download isn't signed by the same developer as this copy, so Brim didn't install it. You can download it from GitHub instead."
            case .tool(let name, _):
                return "The update couldn't be unpacked (\(name)). Nothing was changed."
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Couldn't reach GitHub. Check your connection and try again."
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError {
            return "Brim can't replace itself in this folder. Download the new version from GitHub instead."
        }
        return "The update didn't finish: \(error.localizedDescription)"
    }
}

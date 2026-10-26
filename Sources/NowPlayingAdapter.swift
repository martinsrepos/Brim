import Foundation

/// Reads what any app is playing (Spotify, Music, and browsers like Safari and
/// Chrome) from macOS's "Now Playing" system, and controls it.
///
/// Since macOS 15.4 only Apple-entitled programs may read Now Playing. The
/// open-source mediaremote-adapter (BSD, by Jonas van den Berg, used by Boring
/// Notch) works around that: the system's own `/usr/bin/perl`, which is
/// entitled, loads a small helper framework and prints updates as JSON lines.
/// `build.sh` compiles that framework into Brim.app.
///
/// If anything about it fails (not built, a future macOS blocks it), Brim falls
/// back to talking to Spotify and Music directly.
@MainActor
final class NowPlayingAdapter {
    /// The current Now Playing info, merged from the stream's updates.
    private(set) var state: [String: Any] = [:]
    /// True once the stream has delivered data.
    private(set) var isHealthy = false

    var onChange: (@MainActor ([String: Any]) -> Void)?
    var onFailure: (@MainActor () -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var restarts = 0

    private static var paths: (script: String, framework: String)? {
        guard let script = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let frameworks = Bundle.main.privateFrameworksPath else { return nil }
        let framework = (frameworks as NSString).appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: framework) else { return nil }
        return (script, framework)
    }

    /// Starts streaming. Returns false if the helper isn't part of this build.
    @discardableResult
    func start() -> Bool {
        guard process == nil, let paths = Self.paths else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // Times in microseconds; small debounce so a track change arrives as one update.
        process.arguments = [paths.script, paths.framework, "stream", "--micros", "--debounce=100"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Main queue keeps the chunks in order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.terminated() }
            }
        }
        do {
            try process.run()
        } catch {
            appLog.error("Now Playing helper failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        self.process = process
        return true
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isHealthy = false
    }

    // MARK: Commands

    /// MediaRemote command IDs used by the adapter.
    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    func send(_ command: Command) {
        run(["send", String(command.rawValue)])
    }

    /// Shuffle: 1 off, 3 songs. Repeat: 1 off, 2 one song, 3 all.
    func setShuffle(_ on: Bool) {
        run(["shuffle", on ? "3" : "1"])
    }

    func setRepeat(_ code: Int) {
        run(["repeat", String(code)])
    }

    func seek(to seconds: Double) {
        run(["seek", String(Int(max(0, seconds) * 1_000_000))])
    }

    private func run(_ arguments: [String]) {
        guard let paths = Self.paths else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.framework] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Stream

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            apply(Data(line))
        }
    }

    /// Each line: `{"type":"data","diff":bool,"payload":{...}}`. A diff only
    /// carries changed keys (null = removed); otherwise it's the whole state.
    private func apply(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = message["payload"] as? [String: Any] else { return }
        if message["diff"] as? Bool == true {
            for (key, value) in payload {
                if value is NSNull { state[key] = nil } else { state[key] = value }
            }
        } else {
            state = payload.filter { !($0.value is NSNull) }
        }
        isHealthy = true
        restarts = 0
        onChange?(state)
    }

    private func terminated() {
        process = nil
        let wasHealthy = isHealthy
        isHealthy = false
        state = [:]
        onFailure?()
        // Restart a few times if it was working (e.g. after sleep); give up if it never worked.
        guard wasHealthy, restarts < 3 else { return }
        restarts += 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.start()
        }
    }
}

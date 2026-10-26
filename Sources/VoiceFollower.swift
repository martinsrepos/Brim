import AVFoundation
import Foundation
import Speech

// Follow My Voice: listens through the microphone with Apple's on-device
// speech recognition and works out where in the script you are, so the
// prompter scrolls as you speak and waits when you stop. Nothing leaves the
// Mac: Brim only uses recognition that runs on the Mac itself.

/// The request the microphone feeds, swapped when recognition restarts, and
/// the input level for the listening indicator. Used from the audio thread.
final class SpeechFeed: @unchecked Sendable {   // all state behind `lock`
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var latestLevel: Float = 0

    func setRequest(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = new
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // How loud, for the indicator: the buffer's RMS on a rough 0...1 scale.
        var level: Float = 0
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            let decibels = 20 * log10(max(rms, 0.000_01))
            level = min(max((decibels + 55) / 45, 0), 1)
        }
        lock.lock()
        request?.append(buffer)
        latestLevel = latestLevel * 0.5 + level * 0.5
        lock.unlock()
    }

    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return latestLevel
    }
}

@MainActor
final class VoiceFollower {
    enum Problem {
        case speechNotAllowed, microphoneNotAllowed, noMicrophone
        case languageUnavailable(String)
        case failed(String)

        var message: String {
            switch self {
            case .speechNotAllowed:
                return "Turn on Speech Recognition for Brim in System Settings to follow your voice."
            case .microphoneNotAllowed:
                return "Turn on the Microphone for Brim in System Settings to follow your voice."
            case .noMicrophone:
                return "No microphone found."
            case .languageUnavailable(let name):
                return "\(name) can't be recognized on this Mac without the internet, so it scrolls at a steady speed."
            case .failed(let reason):
                return "Couldn't start listening: \(reason)"
            }
        }

        var settingsURL: URL? {
            switch self {
            case .speechNotAllowed:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            case .microphoneNotAllowed:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            default:
                return nil
            }
        }
    }

    /// The index of the script word you just said.
    var onPosition: ((Int) -> Void)?
    var onProblem: ((Problem) -> Void)?

    private(set) var isListening = false
    let feed = SpeechFeed()

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var lastRestart = Date.distantPast
    private var configObserver: NSObjectProtocol?

    /// The script's words, simplified for comparing (see `normalize`).
    private var words: [String] = []
    /// The next word Brim expects you to say.
    private(set) var cursor = 0
    private var hints: [String] = []

    // MARK: Script

    func load(words newWords: [String]) {
        words = newWords
        cursor = 0
        // Longer, rarer words help the recognizer with names and jargon.
        var seen = Set<String>()
        hints = newWords.filter { $0.count >= 6 && seen.insert($0).inserted }.prefix(100).map { $0 }
    }

    /// You moved the script by hand: listen from there.
    func setCursor(_ index: Int) {
        cursor = min(max(index, 0), words.count)
    }

    // MARK: Listening

    func start(language: String) {
        guard !isListening else { return }
        authorize { [weak self] problem in
            guard let self else { return }
            if let problem { self.onProblem?(problem); return }
            self.begin(language: language)
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        generation += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        feed.setRequest(nil)
        task?.cancel()
        task = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        Diag.event("Teleprompter stopped listening")
    }

    private func authorize(_ done: @escaping @MainActor (Problem?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard status == .authorized else { done(.speechNotAllowed); return }
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized:
                        done(nil)
                    case .notDetermined:
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated { done(granted ? nil : .microphoneNotAllowed) }
                            }
                        }
                    default:
                        done(.microphoneNotAllowed)
                    }
                }
            }
        }
    }

    private func begin(language: String) {
        let locale = Locale(identifier: language == "it" ? "it-IT" : "en-US")
        let name = language == "it" ? "Italian" : "English"
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            onProblem?(.languageUnavailable(name))
            return
        }
        // On the Mac only: never send your voice to a server.
        guard recognizer.supportsOnDeviceRecognition else {
            onProblem?(.languageUnavailable(name))
            return
        }
        self.recognizer = recognizer
        guard startEngine() else { return }
        isListening = true
        startTask()
        // The microphone changed (headphones plugged in, another input
        // chosen): start the audio again with the new one.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isListening else { return }
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
                if !self.startEngine() { self.stop() }
            }
        }
        Diag.event("Teleprompter listening (\(name))")
    }

    private func startEngine() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onProblem?(.noMicrophone)
            return false
        }
        input.removeTap(onBus: 0)
        let feed = self.feed
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            feed.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            input.removeTap(onBus: 0)
            onProblem?(.failed(error.localizedDescription))
            return false
        }
    }

    /// A recognition session. Each one ends after a long silence or when it
    /// has heard a lot; the next starts straight away.
    private func startTask() {
        guard isListening, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = hints
        feed.setRequest(request)
        generation += 1
        let current = generation
        lastRestart = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, current == self.generation, self.isListening else { return }
                    if let text { self.heard(text) }
                    if ended { self.restartTask() }
                }
            }
        }
    }

    private func restartTask() {
        guard isListening else { return }
        feed.setRequest(nil)
        task?.finish()
        task = nil
        generation += 1
        // Don't spin if recognition keeps failing straight away.
        let wait = Date().timeIntervalSince(lastRestart) < 1 ? 1.0 : 0.05
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.startTask()
            }
        }
    }

    // MARK: Matching

    /// What you said so far in this session.
    private func heard(_ transcript: String) {
        let spoken = Self.tokens(in: transcript).map(\.word)
        Diag.count("prompter.heard")
        match(spoken)
        // Keep sessions short, so each stays quick and accurate.
        if spoken.count > 160 { restartTask() }
    }

    /// Finds where the last few words you said are in the script, near where
    /// you were. Tolerates misheard words, skipped words and small detours;
    /// a big jump (skipping a paragraph, going back) needs more agreement.
    private func match(_ spoken: [String]) {
        guard !spoken.isEmpty, !words.isEmpty else { return }
        let tail = Array(spoken.suffix(6))
        let lastTwo = tail.suffix(2)
        let expected = cursor - 1   // the last word matched
        let low = max(0, cursor - 15)
        let high = min(words.count - 1, cursor + (tail.count < 2 ? 3 : 45))
        guard low <= high else { return }

        var best: (index: Int, score: Int, distance: Int)?
        for j in low...high {
            guard lastTwo.contains(where: { Self.similar($0, words[j]) }) else { continue }
            // Walk back through what you said and through the script together,
            // allowing a word or two to be missing on either side.
            var score = 0
            var p = j
            let floor = max(j - 10, 0)
            for word in tail.reversed() where p >= floor {
                var q = p
                while q >= max(floor, p - 2) {
                    if Self.similar(word, words[q]) {
                        score += 1
                        p = q - 1
                        break
                    }
                    q -= 1
                }
            }
            // Forward is likelier than back.
            let distance = j >= expected ? j - expected : (expected - j) * 3
            if let current = best {
                if score > current.score || (score == current.score && distance < current.distance) {
                    best = (j, score, distance)
                }
            } else {
                best = (j, score, distance)
            }
        }
        guard let best else { return }
        let jump = best.index - expected
        let needed = (jump < 0 || jump > 12) ? 3 : 2
        guard best.score >= min(needed, tail.count) else { return }
        guard best.index >= expected || jump < 0 && best.score >= 3 else { return }
        if best.index + 1 != cursor {
            cursor = best.index + 1
            onPosition?(best.index)
        }
    }

    // MARK: Words

    /// Lower case, no accents, letters and digits only ("Perché," -> "perche"),
    /// with the word's place in the text.
    nonisolated static func tokens(in text: String) -> [(word: String, range: NSRange)] {
        let string = text as NSString
        var result: [(String, NSRange)] = []
        let separators = CharacterSet.alphanumerics.inverted
        var location = 0
        while location < string.length {
            let rest = NSRange(location: location, length: string.length - location)
            let start = string.rangeOfCharacter(from: CharacterSet.alphanumerics, options: [], range: rest)
            guard start.location != NSNotFound else { break }
            let after = NSRange(location: start.location, length: string.length - start.location)
            let end = string.rangeOfCharacter(from: separators, options: [], range: after)
            let length = (end.location == NSNotFound ? string.length : end.location) - start.location
            let range = NSRange(location: start.location, length: length)
            let word = string.substring(with: range)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            result.append((word, range))
            location = range.location + range.length
        }
        return result
    }

    /// The same word, allowing for the recognizer's small slips on longer words.
    nonisolated static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        let limit = max(a.count, b.count) >= 7 ? 2 : 1
        return editDistance(a, b, limit: limit) <= limit
    }

    private nonisolated static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }
}

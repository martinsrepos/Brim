import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// The teleprompter: scripts kept in Brim's own library, and the prompter that
// scrolls one in the island, right under the camera.

// MARK: - Scripts

/// One script in the library. Its text is stored next to the index as RTF,
/// so bold and highlights survive.
struct PromptScript: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    /// "en" or "it": for following your voice (next build).
    var language: String
    var modified: Date
    var words: Int

    /// Spoken length at a pace, in whole minutes and seconds.
    func duration(atWordsPerMinute wpm: Double) -> TimeInterval {
        Double(words) / max(wpm, 1) * 60
    }
}

/// The marker you put in a script for a breath: shown as a pause in the
/// prompter.
let pauseMarker = "[pause]"

/// Brim's copies of your scripts, in ~/Library/Application Support/Brim/Scripts.
/// Importing never changes the original file.
@MainActor
@Observable
final class ScriptLibrary {
    /// Newest first.
    private(set) var scripts: [PromptScript] = []

    private let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("scripts.json") }

    /// File types the drop zone and Browse accept.
    static let importTypes: [UTType] = {
        var types: [UTType] = [.plainText, .rtf, .rtfd, .pdf]
        for ext in ["md", "markdown", "docx", "doc", "odt"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    static let importExtensions: Set<String> = ["txt", "text", "md", "markdown", "rtf", "rtfd",
                                                "docx", "doc", "odt", "pdf"]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Brim/Scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([PromptScript].self, from: data) {
            scripts = saved.sorted { $0.modified > $1.modified }
        }
    }

    func script(id: UUID) -> PromptScript? { scripts.first { $0.id == id } }

    /// Reads a file into a new script. Nil when the file can't be read.
    func importFile(_ url: URL) -> PromptScript? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = ScriptReader.read(url) else {
            appLog.error("Teleprompter: couldn't read \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        let title = url.deletingPathExtension().lastPathComponent
        return add(title: title, text: text)
    }

    /// A blank script, for typing or pasting.
    func newScript() -> PromptScript {
        add(title: "New Script", text: NSAttributedString(string: ""))
    }

    private func add(title: String, text: NSAttributedString) -> PromptScript {
        let language = Locale.current.language.languageCode?.identifier == "it" ? "it" : "en"
        let script = PromptScript(id: UUID(), title: title, language: language, modified: Date(),
                                  words: Self.wordCount(text.string))
        write(text, for: script.id)
        scripts.insert(script, at: 0)
        saveIndex()
        return script
    }

    /// The script's text, in the editor's standard look.
    func text(of script: PromptScript) -> NSAttributedString {
        let url = textURL(script.id)
        guard let stored = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                   documentAttributes: nil) else {
            return NSAttributedString(string: "")
        }
        return ScriptReader.normalized(stored)
    }

    /// Saves edited text (and the word count) and moves the script to the top.
    func save(_ id: UUID, text: NSAttributedString) {
        write(text, for: id)
        update(id) {
            $0.words = Self.wordCount(text.string)
            $0.modified = Date()
        }
    }

    func update(_ id: UUID, _ change: (inout PromptScript) -> Void) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        change(&scripts[index])
        scripts.sort { $0.modified > $1.modified }
        saveIndex()
    }

    func remove(_ id: UUID) {
        scripts.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: textURL(id))
        saveIndex()
    }

    private func textURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).rtf") }

    private func write(_ text: NSAttributedString, for id: UUID) {
        // Colours follow light and dark mode in the editor, so none are stored
        // except highlights.
        let plain = NSMutableAttributedString(attributedString: text)
        plain.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: plain.length))
        let range = NSRange(location: 0, length: plain.length)
        if let data = try? plain.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            try? data.write(to: textURL(id), options: .atomic)
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(scripts) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    nonisolated static func wordCount(_ string: String) -> Int {
        string.replacingOccurrences(of: pauseMarker, with: " ", options: .caseInsensitive)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }
}

/// Reads scripts from the formats people write them in.
enum ScriptReader {
    static let baseSize: CGFloat = 15
    static var highlightColor: NSColor { NSColor.systemYellow.withAlphaComponent(0.4) }

    static func read(_ url: URL) -> NSAttributedString? {
        let ext = url.pathExtension.lowercased()
        let raw: NSAttributedString?
        switch ext {
        case "rtf":
            raw = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
        case "rtfd":
            raw = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                          documentAttributes: nil)
        case "docx":
            raw = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: nil)
        case "doc":
            raw = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.docFormat],
                                          documentAttributes: nil)
        case "odt":
            raw = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.openDocument],
                                          documentAttributes: nil)
        case "pdf":
            raw = PDFDocument(url: url)?.string.map { NSAttributedString(string: $0) }
        case "md", "markdown":
            raw = plainText(url).map(markdown)
        default:
            raw = plainText(url).map { NSAttributedString(string: $0) }
        }
        return raw.map(normalized)
    }

    private static func plainText(_ url: URL) -> String? {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    /// Markdown, simply: headings and **bold** become bold, list marks go.
    private static func markdown(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bold = NSFont.boldSystemFont(ofSize: baseSize)
        let regular = NSFont.systemFont(ofSize: baseSize)
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            var line = line
            var lineBold = false
            if let range = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                line.removeSubrange(range)
                lineBold = true
            }
            if let range = line.range(of: "^\\s*([-*+]|\\d+\\.)\\s+", options: .regularExpression) {
                line.removeSubrange(range)
            }
            // **bold** and __bold__: split on the markers, odd parts are bold.
            let parts = line.replacingOccurrences(of: "__", with: "**").components(separatedBy: "**")
            for (i, part) in parts.enumerated() where !part.isEmpty {
                let isBold = lineBold || i % 2 == 1
                result.append(NSAttributedString(string: part, attributes: [.font: isBold ? bold : regular]))
            }
        }
        return result
    }

    /// One look for every script: the system font at one size, bold where the
    /// source was bold, highlights where it had any, nothing else.
    static func normalized(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source.string)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: NSFont.systemFont(ofSize: baseSize), range: full)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        result.addAttribute(.paragraphStyle, value: paragraph, range: full)
        source.enumerateAttributes(in: full) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
                result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseSize), range: range)
            }
            if let background = attributes[.backgroundColor] as? NSColor, background.alphaComponent > 0.05,
               background.usingColorSpace(.sRGB).map({ $0.brightnessComponent < 0.98 || $0.saturationComponent > 0.05 }) ?? true {
                result.addAttribute(.backgroundColor, value: highlightColor, range: range)
            }
        }
        return result
    }
}

// MARK: - Prompter

/// Runs the prompter: which script, where it is, how fast it goes. The
/// island draws it (`PrompterView`); the window lets the pointer reach its
/// controls without opening the panel.
@MainActor
@Observable
final class Prompter {
    private(set) var isActive = false
    private(set) var isPlaying = false
    /// 3, 2, 1 before it starts moving.
    private(set) var countdown: Int?
    private(set) var script: PromptScript?
    /// The script as the prompter shows it.
    private(set) var text = AttributedString()
    private(set) var words = 0
    /// Reached the end.
    private(set) var finished = false
    /// The pointer is over the prompter: its controls show.
    var isHovered = false

    /// How far it has scrolled (points), as of `anchorDate`. While playing it
    /// moves on from there at `pointsPerSecond`.
    private(set) var anchorOffset: CGFloat = 0
    private(set) var anchorDate = Date()
    /// Eases in from a standstill after Play, instead of jerking into motion.
    private(set) var easesIn = false
    /// A jump (a line forward or back) glides there: how far the drawing still
    /// trails the real position, as of `glideStart`.
    private(set) var glideAmount: CGFloat = 0
    private(set) var glideStart = Date.distantPast
    /// A glide is under way (the view keeps drawing frames while paused).
    private(set) var isGliding = false
    /// Follow My Voice is listening.
    private(set) var isListening = false
    /// Why it can't follow your voice right now, and where to fix it.
    private(set) var voiceMessage: String?
    private(set) var voiceSettingsURL: URL?
    /// Moving on its own: listening, or scrolling at a steady speed.
    var isRunning: Bool { isPlaying || isListening }
    private static let easeInDuration: TimeInterval = 0.8
    /// How long the current glide takes: quick for a jump, slower and softer
    /// when it follows your voice word by word.
    private(set) var glideDuration: TimeInterval = 0.35
    /// Height of the whole script as laid out (from the view).
    private(set) var contentHeight: CGFloat = 0

    // Settings
    private(set) var fontSize: Double
    private(set) var width: Double
    private(set) var height: Double
    private(set) var wordsPerMinute: Double
    private(set) var countsDown: Bool
    private(set) var mirrored: Bool
    private(set) var hidesFromSharing: Bool
    private(set) var followsVoice: Bool

    /// Listens and finds your place (see VoiceFollower.swift).
    let voice = VoiceFollower()
    /// The script's words, where each sits in the text and how far down
    /// (in the prompter's own layout) the prompter scrolls to show it.
    @ObservationIgnored private var wordRanges: [NSRange] = []
    @ObservationIgnored private var wordOffsets: [CGFloat] = []

    static let fontSizeRange: ClosedRange<Double> = 18...44
    static let widthRange: ClosedRange<Double> = 360...760
    static let heightRange: ClosedRange<Double> = 140...380
    static let speedRange: ClosedRange<Double> = 60...240

    @ObservationIgnored weak var library: ScriptLibrary?
    /// Banners wait while it's on (wired in App).
    @ObservationIgnored var onActiveChange: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var hotKeys: PrompterHotKeys?
    @ObservationIgnored private var playStarted: Date?
    @ObservationIgnored private var playedBefore: TimeInterval = 0

    init() {
        let d = UserDefaults.standard
        fontSize = (d.object(forKey: "prompter.fontSize") as? Double ?? 26).clamped(to: Self.fontSizeRange)
        width = (d.object(forKey: "prompter.width") as? Double ?? 520).clamped(to: Self.widthRange)
        height = (d.object(forKey: "prompter.height") as? Double ?? 260).clamped(to: Self.heightRange)
        wordsPerMinute = (d.object(forKey: "prompter.wpm") as? Double ?? 130).clamped(to: Self.speedRange)
        countsDown = d.object(forKey: "prompter.countdown") as? Bool ?? true
        mirrored = d.bool(forKey: "prompter.mirrored")
        hidesFromSharing = d.object(forKey: "prompter.hideFromSharing") as? Bool ?? true
        followsVoice = d.object(forKey: "prompter.followVoice") as? Bool ?? true
        voice.onPosition = { [weak self] index in self?.follow(to: index) }
        voice.onProblem = { [weak self] problem in self?.voiceFailed(problem) }
    }

    // MARK: Geometry

    var lineHeight: CGFloat { CGFloat(fontSize) * 1.32 }

    /// The furthest it scrolls: the last line on the reading line.
    var maxOffset: CGFloat { max(contentHeight - lineHeight, 0) }

    var pointsPerSecond: CGFloat {
        guard words > 0, contentHeight > 0 else { return 0 }
        return CGFloat(wordsPerMinute / 60) * contentHeight / CGFloat(words)
    }

    /// Where the script really is.
    func logicalPosition(at date: Date) -> CGFloat {
        guard isPlaying else { return anchorOffset }
        let elapsed = max(date.timeIntervalSince(anchorDate), 0)
        let ramp = Self.easeInDuration
        let travelled: Double
        if easesIn {
            // Speed grows evenly from zero over the ramp, then holds.
            travelled = elapsed < ramp ? elapsed * elapsed / (2 * ramp) : elapsed - ramp / 2
        } else {
            travelled = elapsed
        }
        let moved = anchorOffset + pointsPerSecond * CGFloat(travelled)
        return min(max(moved, 0), maxOffset)
    }

    /// Where the script is drawn: the real position, minus what's left of a glide.
    func position(at date: Date) -> CGFloat {
        logicalPosition(at: date) - glideRemaining(at: date)
    }

    private func glideRemaining(at date: Date) -> CGFloat {
        guard glideAmount != 0 else { return 0 }
        let t = min(max(date.timeIntervalSince(glideStart) / glideDuration, 0), 1)
        let eased = 1 - pow(1 - t, 3)   // ease out
        return glideAmount * CGFloat(1 - eased)
    }

    /// 0...1, how far through the script.
    func progress(at date: Date) -> CGFloat {
        maxOffset > 0 ? (position(at: date) / maxOffset).clamped(to: 0...1) : 0
    }

    /// Time left at the current pace.
    func remaining(at date: Date) -> TimeInterval {
        let pps = pointsPerSecond
        guard pps > 0 else { return script?.duration(atWordsPerMinute: wordsPerMinute) ?? 0 }
        return TimeInterval((maxOffset - position(at: date)) / pps)
    }

    func setContentHeight(_ value: CGFloat) {
        guard abs(value - contentHeight) > 0.5 else { return }
        // Keep the same place in the text when the layout changes (text size).
        let fraction = contentHeight > 0 ? logicalPosition(at: Date()) / contentHeight : 0
        contentHeight = value
        anchorOffset = min(fraction * value, maxOffset)
        anchorDate = Date()
        layoutWords()
    }

    private func reanchor() {
        let now = Date()
        anchorOffset = logicalPosition(at: now)
        anchorDate = now
        easesIn = false
    }

    // MARK: Running

    /// Opens the prompter with a script, paused at the top (or counting down).
    func start(_ script: PromptScript) {
        guard let library else { return }
        let source = library.text(of: script)
        // Back from editing the script that's open: keep your place.
        if isActive, self.script?.id == script.id {
            pause()
            let display = Self.display(source)
            text = display.text
            words = display.words
            self.script = script
            loadWords()
            return
        }
        countdownTask?.cancel()
        pause()
        self.script = script
        UserDefaults.standard.set(script.id.uuidString, forKey: "prompter.lastScript")
        let display = Self.display(source)
        text = display.text
        words = display.words
        loadWords()
        anchorOffset = 0
        anchorDate = Date()
        contentHeight = 0
        finished = false
        isPlaying = false
        playedBefore = 0
        playStarted = nil
        if !isActive {
            isActive = true
            onActiveChange?(true)
            holdAwake(true)
            startTicker()
        }
        Diag.event("Teleprompter started (\(words) words)")
        // Following your voice starts when you start speaking: no countdown.
        if countsDown && !followsVoice { runCountdown() } else { play() }
    }

    /// The shortcut: starts the last script, or pauses and resumes.
    func toggle() {
        if isActive { togglePlay(); return }
        guard let library,
              let id = UserDefaults.standard.string(forKey: "prompter.lastScript").flatMap(UUID.init(uuidString:)),
              let script = library.script(id: id) ?? library.scripts.first else { return }
        start(script)
    }

    func togglePlay() {
        guard isActive else { return }
        if countdown != nil {
            countdownTask?.cancel()
            countdown = nil
            return
        }
        isRunning ? pause() : play()
    }

    func play() {
        guard isActive else { return }
        if finished || anchorOffset >= maxOffset - 1 && maxOffset > 0 {
            anchorOffset = 0
            finished = false
        }
        if followsVoice {
            startListening()
            return
        }
        anchorDate = Date()
        easesIn = true
        playStarted = Date()
        isPlaying = true
    }

    func pause() {
        if isListening {
            voice.stop()
            isListening = false
        }
        guard isPlaying else { return }
        reanchor()
        isPlaying = false
        if let started = playStarted { playedBefore += Date().timeIntervalSince(started) }
        playStarted = nil
    }

    func stop() {
        guard isActive else { return }
        countdownTask?.cancel()
        countdown = nil
        pause()
        isActive = false
        isHovered = false
        ticker?.invalidate()
        ticker = nil
        holdAwake(false)
        onActiveChange?(false)
        Diag.event("Teleprompter stopped")
    }

    func faster() { setSpeed(wordsPerMinute + 10) }
    func slower() { setSpeed(wordsPerMinute - 10) }

    /// Moves by lines, gliding there (the shortcuts, the buttons, the dial).
    /// Works while it's playing too.
    func nudge(lines: Double) {
        guard isActive else { return }
        let now = Date()
        let trailing = glideRemaining(at: now)
        reanchor()
        let target = min(max(anchorOffset + CGFloat(lines) * lineHeight, 0), maxOffset)
        let moved = target - anchorOffset
        anchorOffset = target
        if target < maxOffset { finished = false }
        glide(by: trailing + moved, from: now)
        voice.setCursor(wordIndex(at: target))
    }

    /// Moves by points, directly (a scroll wheel or trackpad over the prompter).
    func scroll(by points: CGFloat) {
        guard isActive else { return }
        reanchor()
        anchorOffset = min(max(anchorOffset + points, 0), maxOffset)
        if anchorOffset < maxOffset { finished = false }
        voice.setCursor(wordIndex(at: anchorOffset))
    }

    func restart() {
        guard isActive else { return }
        let now = Date()
        let trailing = glideRemaining(at: now)
        reanchor()
        let moved = -anchorOffset
        anchorOffset = 0
        finished = false
        glide(by: trailing + moved, from: now)
    }

    private func glide(by amount: CGFloat, from date: Date, duration: TimeInterval = 0.35) {
        glideDuration = duration
        glideAmount = amount
        glideStart = date
        isGliding = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.05) * 1_000_000_000))
            guard let self, self.glideStart == date else { return }
            self.glideAmount = 0
            self.isGliding = false
        }
    }

    // MARK: Following your voice

    private func startListening() {
        voiceMessage = nil
        voiceSettingsURL = nil
        isListening = true
        voice.setCursor(wordIndex(at: anchorOffset))
        voice.start(language: script?.language ?? "en")
    }

    private func voiceFailed(_ problem: VoiceFollower.Problem) {
        isListening = false
        voiceMessage = problem.message
        voiceSettingsURL = problem.settingsURL
        // This language can't be done on the Mac: a steady speed instead.
        if case .languageUnavailable = problem, isActive {
            anchorDate = Date()
            easesIn = true
            playStarted = Date()
            isPlaying = true
        }
    }

    /// You said word `index`: glide so that it sits on the reading line.
    private func follow(to index: Int) {
        guard isActive, isListening, index < wordOffsets.count else { return }
        let target = min(wordOffsets[index], maxOffset)
        let now = Date()
        let trailing = glideRemaining(at: now)
        let moved = target - anchorOffset
        guard abs(moved) > 0.5 else { return }
        anchorOffset = target
        glide(by: trailing + moved, from: now, duration: 0.7)
        if index >= wordOffsets.count - 1 {
            finished = true
            pause()
        }
    }

    /// The first word at or below a scroll position.
    private func wordIndex(at offset: CGFloat) -> Int {
        guard !wordOffsets.isEmpty else { return 0 }
        var low = 0, high = wordOffsets.count - 1
        while low < high {
            let mid = (low + high) / 2
            if wordOffsets[mid] < offset - 1 { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func setFollowsVoice(_ on: Bool) {
        let wasRunning = isRunning
        if wasRunning { pause() }
        followsVoice = on
        save(on, "followVoice")
        voiceMessage = nil
        if wasRunning { play() }
    }

    func dismissVoiceMessage() {
        voiceMessage = nil
        voiceSettingsURL = nil
    }

    private func loadWords() {
        let tokens = VoiceFollower.tokens(in: String(text.characters))
        wordRanges = tokens.map(\.range)
        voice.load(words: tokens.map(\.word))
        layoutWords()
    }

    /// Lays the script out the way the prompter draws it, to know how far
    /// down each word is. Scaled to the height SwiftUI measured, so small
    /// differences between the two layouts don't add up.
    private func layoutWords() {
        guard contentHeight > 0, !wordRanges.isEmpty else {
            wordOffsets = []
            return
        }
        let storage = NSTextStorage(attributedString: Self.measuringString(text, fontSize: fontSize))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: max(width - 52, 1), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let total = max(layout.usedRect(for: container).height, 1)
        let scale = contentHeight / total
        let length = storage.length
        wordOffsets = wordRanges.map { range in
            guard range.location < length else { return contentHeight }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let x = layout.location(forGlyphAt: glyphs.location).x
            // Partway along a line, partway down it: the text keeps moving
            // gently as you read along instead of jumping a line at a time.
            let along = used.width > 0 ? min(max((x - used.minX) / used.width, 0), 1) : 0
            return (line.minY + along * line.height * 0.9) * scale
        }
    }

    private static func measuringString(_ text: AttributedString, fontSize: Double) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.32
        for run in text.runs {
            let bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
            let font = NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .semibold)
            result.append(NSAttributedString(string: String(text[run.range].characters),
                                             attributes: [.font: font, .paragraphStyle: paragraph]))
        }
        return result
    }

    private func runCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for n in [3, 2, 1] {
                guard let self, !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { self.countdown = n }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.countdown = nil }
            self.play()
        }
    }

    /// Notices the end while playing.
    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard isPlaying, contentHeight > 0, logicalPosition(at: Date()) >= maxOffset - 0.5 else { return }
        pause()
        anchorOffset = maxOffset
        finished = true
    }

    /// The display stays on while the prompter is open.
    private func holdAwake(_ on: Bool) {
        if on, assertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Brim: Teleprompter" as CFString, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    // MARK: Settings

    func setFontSize(_ value: Double) { fontSize = value.clamped(to: Self.fontSizeRange); save(fontSize, "fontSize") }
    func setWidth(_ value: Double) { width = value.clamped(to: Self.widthRange); save(width, "width") }
    func setHeight(_ value: Double) { height = value.clamped(to: Self.heightRange); save(height, "height") }
    func setSpeed(_ value: Double) {
        reanchor()
        wordsPerMinute = (value / 5).rounded() * 5
        wordsPerMinute = wordsPerMinute.clamped(to: Self.speedRange)
        save(wordsPerMinute, "wpm")
    }
    func setCountsDown(_ on: Bool) { countsDown = on; save(on, "countdown") }
    func setMirrored(_ on: Bool) { mirrored = on; save(on, "mirrored") }
    func setHidesFromSharing(_ on: Bool) { hidesFromSharing = on; save(on, "hideFromSharing") }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: "prompter.\(key)")
    }

    // MARK: Shortcuts

    func startHotKeys() {
        guard hotKeys == nil else { return }
        let keys = PrompterHotKeys { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggle: self.toggle()
            case .faster: if self.isActive { self.faster() }
            case .slower: if self.isActive { self.slower() }
            case .forward: self.nudge(lines: 0.5)
            case .back: self.nudge(lines: -0.5)
            case .stop: self.stop()
            }
        }
        keys.start()
        hotKeys = keys
    }

    // MARK: Text

    /// The script as the prompter draws it: bold stays bold, highlights turn
    /// yellow, pause markers become a pause sign.
    static func display(_ source: NSAttributedString) -> (text: AttributedString, words: Int) {
        var result = AttributedString()
        let full = NSRange(location: 0, length: source.length)
        let string = source.string as NSString
        source.enumerateAttributes(in: full) { attributes, range, _ in
            var piece = AttributedString(string.substring(with: range))
            if let font = attributes[.font] as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            if attributes[.backgroundColor] != nil {
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color(red: 1, green: 0.84, blue: 0.3)
            }
            result += piece
        }
        while let range = result.range(of: pauseMarker, options: .caseInsensitive) {
            var sign = AttributedString("\u{23F8}\u{FE0E}")
            sign[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.white.opacity(0.4)
            result.replaceSubrange(range, with: sign)
        }
        return (result, ScriptLibrary.wordCount(source.string))
    }
}

// MARK: - Shortcuts

/// The teleprompter's global shortcuts, for the keyboard or buttons on the
/// MX Creative Console (set in Logi Options+).
final class PrompterHotKeys: @unchecked Sendable {   // used on the main thread only
    enum Action: UInt32 { case toggle = 1, faster, slower, forward, back, stop }

    private let onPress: @MainActor (Action) -> Void
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4850524D   // "HPRM"

    static let labels: [(String, String)] = [
        ("\u{2303}\u{2325}\u{2318}P", "Start, pause or resume"),
        ("\u{2303}\u{2325}\u{2318}=", "Faster"),
        ("\u{2303}\u{2325}\u{2318}\u{2212}", "Slower"),
        ("\u{2303}\u{2325}\u{2318}]", "Forward half a line (dial right)"),
        ("\u{2303}\u{2325}\u{2318}[", "Back half a line (dial left)"),
        ("\u{2303}\u{2325}\u{2318}.", "Close"),
    ]

    init(onPress: @escaping @MainActor (Action) -> Void) {
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
            guard id.signature == PrompterHotKeys.signature,
                  let action = PrompterHotKeys.Action(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<PrompterHotKeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.onPress(action) }   // Carbon calls this on the main thread
            return noErr
        }, 1, &type, context, &handler)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let keys: [(Int, Action)] = [(kVK_ANSI_P, .toggle), (kVK_ANSI_Equal, .faster), (kVK_ANSI_Minus, .slower),
                                     (kVK_ANSI_RightBracket, .forward), (kVK_ANSI_LeftBracket, .back),
                                     (kVK_ANSI_Period, .stop)]
        for (key, action) in keys {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key), modifiers,
                                             EventHotKeyID(signature: Self.signature, id: action.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { appLog.error("Teleprompter shortcut \(action.rawValue) is taken by another app") }
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

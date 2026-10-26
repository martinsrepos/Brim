import AppKit
import Observation
import SwiftUI

// The script editor: a small window for tidying a script before you read it.
// The island can't take typing (it never becomes the key window), so editing
// happens here.

/// One editor window per script; opening a script that's already open brings
/// its window forward.
@MainActor
final class ScriptEditorWindows {
    private var open: [UUID: ScriptEditorController] = [:]

    func show(_ script: PromptScript, library: ScriptLibrary, prompter: Prompter) {
        if let existing = open[script.id] {
            existing.bringForward()
            return
        }
        let controller = ScriptEditorController(script: script, library: library, prompter: prompter) { [weak self] id in
            self?.open[id] = nil
        }
        open[script.id] = controller
        controller.bringForward()
    }

    /// Saves every open editor (before the prompter starts or Brim quits).
    func saveAll() {
        for controller in open.values { controller.model.saveNow() }
    }
}

/// What the editor shows and does. The text itself lives in the NSTextView.
@MainActor
@Observable
final class ScriptEditorModel {
    let id: UUID
    var title: String
    var language: String
    private(set) var words: Int
    /// The selection (or what you type next) is bold / highlighted: the
    /// toolbar buttons show it.
    private(set) var isBold = false
    private(set) var isHighlighted = false
    let library: ScriptLibrary
    let prompter: Prompter

    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var onStart: (() -> Void)?

    init(script: PromptScript, library: ScriptLibrary, prompter: Prompter) {
        id = script.id
        title = script.title
        language = script.language
        words = script.words
        self.library = library
        self.prompter = prompter
    }

    var readingTime: String {
        let seconds = Int((Double(words) / prompter.wordsPerMinute * 60).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func textChanged() {
        words = ScriptLibrary.wordCount(textView?.string ?? "")
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func setTitle(_ value: String) {
        title = value
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        library.update(id) { $0.title = trimmed.isEmpty ? "Untitled" : trimmed }
    }

    func setLanguage(_ value: String) {
        language = value
        library.update(id) { $0.language = value }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let textView, let storage = textView.textStorage else { return }
        library.save(id, text: NSAttributedString(attributedString: storage))
    }

    func startPrompter() {
        saveNow()
        guard let script = library.script(id: id) else { return }
        prompter.start(script)
        onStart?()
    }

    // MARK: Formatting

    func toggleBold() {
        guard let textView = textView as? ScriptTextView else { return }
        textView.toggleBold()
        textView.window?.makeFirstResponder(textView)
        updateFormatting()
    }

    func toggleHighlight() {
        guard let textView = textView as? ScriptTextView else { return }
        textView.toggleHighlight()
        textView.window?.makeFirstResponder(textView)
        updateFormatting()
    }

    /// Called when the selection moves.
    func updateFormatting() {
        guard let textView = textView as? ScriptTextView else { return }
        let bold = textView.selectionIsBold
        let highlighted = textView.selectionIsHighlighted
        if bold != isBold { isBold = bold }
        if highlighted != isHighlighted { isHighlighted = highlighted }
    }

    func insertPause() {
        guard let textView else { return }
        let range = textView.selectedRange()
        // A space either side, unless there's one already.
        let text = textView.string as NSString
        let before = range.location > 0 ? text.substring(with: NSRange(location: range.location - 1, length: 1)) : " "
        let insert = (before == " " || before == "\n" ? "" : " ") + pauseMarker + " "
        textView.insertText(insert, replacementRange: range)
        textView.window?.makeFirstResponder(textView)
    }

    func showFind() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }
}

// MARK: - Window

@MainActor
final class ScriptEditorController: NSObject, NSWindowDelegate {
    let model: ScriptEditorModel
    private let window: NSWindow
    private let onClose: (UUID) -> Void

    init(script: PromptScript, library: ScriptLibrary, prompter: Prompter, onClose: @escaping (UUID) -> Void) {
        let model = ScriptEditorModel(script: script, library: library, prompter: prompter)
        self.model = model
        self.onClose = onClose
        let host = NSHostingController(rootView: ScriptEditorView(model: model, text: library.text(of: script)))
        window = NSWindow(contentViewController: host)
        super.init()
        window.title = script.title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 560))
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.delegate = self
        window.center()
        // Each new window a little lower and to the right, like documents.
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX + CGFloat(Int.random(in: 0...3)) * 22,
                                            y: window.frame.maxY - CGFloat(Int.random(in: 0...3)) * 22))
        // Starting the prompter closes the editor (saved); the prompter's
        // Edit button opens it again.
        model.onStart = { [weak self] in self?.window.close() }
    }

    func bringForward() {
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.saveNow()
        onClose(model.id)
    }
}

// MARK: - Views

struct ScriptEditorView: View {
    let model: ScriptEditorModel
    let text: NSAttributedString

    var body: some View {
        VStack(spacing: 0) {
            // Title, as big as a document title, in the transparent title bar.
            TextField("Title", text: Binding(get: { model.title }, set: { model.setTitle($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 8)

            toolbar
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            Divider()

            ScriptTextEditor(model: model, initialText: text)

            Divider()

            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    /// Round buttons like the island's own, grouped: formatting, the pause
    /// marker, then the language and Find on the right.
    private var toolbar: some View {
        HStack(spacing: 6) {
            ToolButton(symbol: "bold", label: "Bold (\u{2318}B)", isOn: model.isBold) { model.toggleBold() }
            ToolButton(symbol: "highlighter", label: "Highlight: select words to stand out in yellow",
                       isOn: model.isHighlighted) { model.toggleHighlight() }
            ToolButton(symbol: "pause", label: "Insert a Pause") { model.insertPause() }
                .padding(.leading, 8)
            Spacer()
            Picker("Language", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                Text("English").tag("en")
                Text("Italiano").tag("it")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("The language you'll read in, for following your voice")
            ToolButton(symbol: "magnifyingglass", label: "Find and Replace (\u{2318}F)") { model.showFind() }
                .padding(.leading, 4)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(model.words) words \u{00B7} about \(model.readingTime) at \(Int(model.prompter.wordsPerMinute)) words a minute")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button {
                model.startPrompter()
            } label: {
                Label("Start Prompter", systemImage: "play.fill")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.words == 0)
        }
    }
}

/// A round toolbar button, the same shape as the island's header buttons;
/// tinted while its format is on.
private struct ToolButton: View {
    let symbol: String
    let label: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressedScale: 0.88))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// The text area: an AppKit text view, for undo, Find and Replace, and rich
/// text.
struct ScriptTextEditor: NSViewRepresentable {
    let model: ScriptEditorModel
    let initialText: NSAttributedString

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, built by hand: the pause tags use its temporary attributes.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let textView = ScriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.keptStorage = storage   // built by hand, so nothing else holds it
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(initialText)
        textView.applyStandardLook()
        textView.delegate = context.coordinator
        model.textView = textView

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ScriptEditorModel
        init(model: ScriptEditorModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            MainActor.assumeIsolated {
                (model.textView as? ScriptTextView)?.markPauses()
                model.textChanged()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated { model.updateFormatting() }
        }
    }
}

/// The editor's text view: the standard look, the Bold and Highlight
/// commands, and pause markers shown as tags.
final class ScriptTextView: NSTextView {
    /// The text storage: a text view built from its own parts doesn't keep it.
    var keptStorage: NSTextStorage?
    private var baseFont: NSFont { NSFont.systemFont(ofSize: ScriptReader.baseSize) }

    /// System font, label colour (light and dark mode), comfortable spacing.
    func applyStandardLook() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        typingAttributes = [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        if let storage = textStorage {
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                 range: NSRange(location: 0, length: storage.length))
        }
        markPauses()
    }

    /// Pause markers look like small grey tags (display only, not saved).
    func markPauses() {
        guard let layoutManager, let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        let text = storage.string as NSString
        var search = full
        while search.length > 0 {
            let found = text.range(of: pauseMarker, options: .caseInsensitive, range: search)
            guard found.location != NSNotFound else { break }
            layoutManager.addTemporaryAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                                  .backgroundColor: NSColor.quaternaryLabelColor],
                                                 forCharacterRange: found)
            let next = found.location + found.length
            search = NSRange(location: next, length: full.length - next)
        }
    }

    /// Pasted text arrives plain, in the script's own look.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        let range = selectedRange()
        insertText(NSAttributedString(string: string, attributes: typingAttributes), replacementRange: range)
    }

    @objc func toggleBold() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            // Nothing selected: what you type next.
            let current = typingAttributes[.font] as? NSFont ?? baseFont
            let isBold = current.fontDescriptor.symbolicTraits.contains(.bold)
            typingAttributes[.font] = isBold ? baseFont : NSFont.boldSystemFont(ofSize: ScriptReader.baseSize)
            return
        }
        let firstFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        let makeBold = !(firstFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(.font, value: makeBold ? NSFont.boldSystemFont(ofSize: ScriptReader.baseSize) : baseFont,
                             range: range)
        didChangeText()
    }

    /// What Bold and Highlight would act on: the selection, or the typing style.
    var selectionIsBold: Bool {
        let range = selectedRange()
        let font: NSFont?
        if range.length > 0, let storage = textStorage, range.location < storage.length {
            font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        } else {
            font = typingAttributes[.font] as? NSFont
        }
        return font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
    }

    var selectionIsHighlighted: Bool {
        let range = selectedRange()
        if range.length > 0, let storage = textStorage, range.location < storage.length {
            return storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil
        }
        return typingAttributes[.backgroundColor] != nil
    }

    @objc func toggleHighlight() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            // Nothing selected: what you type next.
            if typingAttributes[.backgroundColor] == nil {
                typingAttributes[.backgroundColor] = ScriptReader.highlightColor
            } else {
                typingAttributes[.backgroundColor] = nil
            }
            return
        }
        let highlighted = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        if highlighted {
            storage.removeAttribute(.backgroundColor, range: range)
        } else {
            storage.addAttribute(.backgroundColor, value: ScriptReader.highlightColor, range: range)
        }
        didChangeText()
    }

}

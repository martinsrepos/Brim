import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The prompter in the island

/// The script scrolling under the camera. The line you're on sits a third of
/// the way down, closest to the lens; lines you've read fade out above it and
/// the next ones fade in below. Controls appear while the pointer is over it
/// or it's paused.
struct PrompterView: View {
    let prompter: Prompter
    let size: CGSize
    /// Room left at the top for a MacBook's notch.
    let topInset: CGFloat
    /// Opens the script in the editor.
    let onEdit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sideMargin: CGFloat = 26

    var body: some View {
        let textHeight = max(size.height - topInset, 1)
        let readingLine = (textHeight * 0.34).rounded()
        let showsControls = prompter.countdown == nil && (prompter.isHovered || !prompter.isRunning)

        ZStack(alignment: .topLeading) {
            // Every frame the display draws (no fixed rate, so no stutter),
            // while it moves or glides.
            TimelineView(.animation(paused: !(prompter.isPlaying || prompter.isGliding))) { context in
                PrompterText(prompter: prompter, width: size.width - sideMargin * 2)
                    .offset(x: sideMargin,
                            y: readingLine - prompter.lineHeight * 0.55 - prompter.position(at: context.date))
            }
            .frame(width: size.width, height: textHeight, alignment: .topLeading)
            .clipped()
            .mask(fade(height: textHeight, readingLine: readingLine))
            // For a teleprompter mirror (glass in front of the camera).
            .scaleEffect(x: prompter.mirrored ? -1 : 1)
            .opacity(prompter.countdown == nil ? 1 : 0.25)

            // The mark on the reading line.
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.orange.opacity(prompter.isRunning ? 1 : 0.6))
                .shadow(color: .orange.opacity(prompter.isRunning ? 0.5 : 0), radius: 4)
                .offset(x: 8, y: readingLine - 7)

            if let count = prompter.countdown {
                Text("\(count)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .frame(width: size.width, height: textHeight)
                    .transition(.opacity)
            }

            if prompter.finished && !prompter.isHovered {
                Text("End")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                    .frame(width: size.width, height: textHeight, alignment: .bottom)
            }

            // Why it isn't following your voice, above the controls.
            if let message = prompter.voiceMessage {
                VoiceMessage(message: message, settingsURL: prompter.voiceSettingsURL) {
                    prompter.dismissVoiceMessage()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, showsControls ? 46 : 14)
                .frame(width: size.width, height: textHeight, alignment: .bottom)
                .transition(.opacity)
            }

            controls
                .padding(.bottom, 12)
                .frame(width: size.width, height: textHeight, alignment: .bottom)
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)

            topBar
                .frame(width: size.width, alignment: .top)
                .padding(.top, 12)
                .opacity(prompter.countdown == nil ? 1 : 0)

            // How far through the script, along the bottom edge.
            // A faint track with the part you've read filled in.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !(prompter.isPlaying || prompter.isGliding))) { context in
                let track = size.width - 64
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: track, height: 4)
                    Capsule()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: max(4, track * prompter.progress(at: context.date)), height: 4)
                }
            }
            .offset(x: 32, y: textHeight - 9)
            .opacity(prompter.countdown == nil ? 1 : 0)
        }
        .padding(.top, topInset)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.2), value: showsControls)
        .animation(.easeOut(duration: 0.2), value: prompter.isHovered)
    }

    /// Read lines fade to a shadow, the end of the window fades out.
    private func fade(height: CGFloat, readingLine: CGFloat) -> LinearGradient {
        let line = prompter.lineHeight
        let s1 = max((readingLine - line * 1.4) / height, 0.02)
        let s2 = max((readingLine - line * 0.6) / height, s1 + 0.01)
        let s3 = max(0.8, s2 + 0.01)
        return LinearGradient(stops: [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black.opacity(0.28), location: s1),
            .init(color: .black, location: s2),
            .init(color: .black, location: min(s3, 0.98)),
            .init(color: .black.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            HeaderMenuButton(symbol: "pencil", tint: nil, isOpen: false, label: "Edit Script") {
                prompter.pause()
                onEdit()
            }
            HeaderMenuButton(symbol: "chevron.left.2", tint: nil, isOpen: false, label: "Back a Line") {
                prompter.nudge(lines: -1)
            }
            HeaderMenuButton(symbol: prompter.finished ? "arrow.counterclockwise" : (prompter.isRunning ? "pause.fill" : "play.fill"),
                             tint: nil, isOpen: true,
                             label: prompter.finished ? "Start Again"
                                : (prompter.isRunning ? "Pause" : (prompter.followsVoice ? "Start Listening" : "Play"))) {
                if prompter.finished { prompter.restart(); prompter.play() } else { prompter.togglePlay() }
            }
            HeaderMenuButton(symbol: "chevron.right.2", tint: nil, isOpen: false, label: "Forward a Line") {
                prompter.nudge(lines: 1)
            }
            // Follow My Voice, or a steady speed.
            HeaderMenuButton(symbol: "waveform", tint: prompter.followsVoice ? .orange : nil,
                             isOpen: false,
                             label: prompter.followsVoice ? "Following Your Voice (click for a steady speed)"
                                                          : "Steady Speed (click to follow your voice)") {
                prompter.setFollowsVoice(!prompter.followsVoice)
            }
            if !prompter.followsVoice {
            HStack(spacing: 2) {
                Button { prompter.slower() } label: {
                    Image(systemName: "minus").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .help("Slower")
                Text("\(Int(prompter.wordsPerMinute))")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 26)
                Button { prompter.faster() } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .help("Faster")
            }
            .buttonStyle(PressStyle(pressedScale: 0.85))
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 4)
            .frame(height: 26)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .help("Words a minute")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            HeaderMenuButton(symbol: "xmark", tint: nil, isOpen: false, label: "Close Prompter") {
                prompter.stop()
            }
        }
        .foregroundStyle(.white)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: prompter.followsVoice)
    }

    /// The script's title (on hover) and the time left (always).
    private var topBar: some View {
        HStack(spacing: 8) {
            if prompter.isListening {
                ListeningIndicator(feed: prompter.voice.feed)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            Text(prompter.script?.title ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(prompter.isHovered ? 1 : 0)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(prompter.remaining(at: context.date)))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.numericText(countsDown: true))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .help("Time left at this speed")
            }
        }
        .padding(.horizontal, 18)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Four bars that move with your voice while it's listening.
private struct ListeningIndicator: View {
    let feed: SpeechFeed

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
            let level = CGFloat(feed.level)
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { bar in
                    let shape: [CGFloat] = [0.55, 1, 0.75, 0.45]
                    Capsule()
                        .fill(Color.orange)
                        .frame(width: 3, height: 4 + 12 * level * shape[bar])
                }
            }
            .frame(height: 16)
            .animation(.easeOut(duration: 0.08), value: level)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .help("Listening")
    }
}

/// A short note when it can't follow your voice, with a way to fix it.
private struct VoiceMessage: View {
    let message: String
    let settingsURL: URL?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.slash")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let settingsURL {
                Button("Open Settings") { NSWorkspace.shared.open(settingsURL) }
                    .buttonStyle(PressStyle())
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.primary.opacity(0.15)))
                    .fixedSize()
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle(pressedScale: 0.85))
            .help("Dismiss")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.55)))
    }
}

/// The script's text, laid out once at the prompter's width; reports its
/// height so the scrolling knows where the end is.
private struct PrompterText: View {
    let prompter: Prompter
    let width: CGFloat

    var body: some View {
        Text(prompter.text)
            .font(.system(size: prompter.fontSize, weight: .semibold))
            .lineSpacing(prompter.fontSize * 0.32)
            .foregroundStyle(.white)
            .frame(width: max(width, 1), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { prompter.setContentHeight(geometry.size.height) }
                        .onChange(of: geometry.size.height) { _, height in prompter.setContentHeight(height) }
                }
            }
    }
}

// MARK: - The panel's teleprompter section

/// In the panel, in the player's place: drop a script or browse for one, and
/// the recent ones. Picking one opens it in the editor.
struct PrompterLibraryView: View {
    let vm: NotchViewModel

    @Environment(NotchUIState.self) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Teleprompter")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    vm.openScript(vm.scripts.newScript())
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(PressStyle())
                .help("Write or paste a new script")
            }

            dropZone

            ForEach(vm.scripts.scripts.prefix(3)) { script in
                ScriptRow(script: script, wordsPerMinute: vm.prompter.wordsPerMinute,
                          open: { vm.openScript(script) },
                          start: { vm.prompter.start(script) },
                          remove: { withAnimation(.easeOut(duration: 0.2)) { vm.scripts.remove(script.id) } })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Anywhere on the section takes the drop, not just the zone.
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { ui.scriptDropTargeted },
                                                     set: { ui.scriptDropTargeted = $0 })) { providers in
            vm.importDroppedScript(providers)
        }
    }

    private var dropZone: some View {
        let targeted = ui.scriptDropTargeted
        return HStack(spacing: 10) {
            Image(systemName: targeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Drop a script here")
                    .font(.system(size: 12, weight: .semibold))
                Text("Text, Word, Markdown or PDF")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Browse\u{2026}") { vm.browseForScript() }
                .buttonStyle(PressStyle())
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(targeted ? 0.1 : 0.04))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.18),
                              style: StrokeStyle(lineWidth: 1, dash: targeted ? [] : [4, 3]))
        }
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: targeted)
    }
}

/// A recent script: click to edit, the play button starts it straight away.
private struct ScriptRow: View {
    let script: PromptScript
    let wordsPerMinute: Double
    let open: () -> Void
    let start: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(script.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(PrompterView.clock(script.duration(atWordsPerMinute: wordsPerMinute)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            Button(action: start) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle(pressedScale: 0.85))
            .help("Start Prompter")
            .disabled(script.words == 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help("Edit")
        .contextMenu {
            Button("Edit", action: open)
            Button("Start Prompter", action: start)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

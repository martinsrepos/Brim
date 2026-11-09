import SwiftUI

/// On the lock screen, clicking the artwork fills the screen with it: the
/// cover, large, over a blurred copy of itself, with the song and the
/// controls underneath. Click the artwork or anywhere around it to put it away.
/// Its window fades in and out (see `NotchWindowController`), so the view
/// itself keeps no state.
struct FullScreenArtworkView: View {
    let media: MediaController
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.height * 0.46, proxy.size.width * 0.4, 520)
            ZStack {
                background(in: proxy.size)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)

                VStack(spacing: 28) {
                    cover(side: side)
                    if let track = media.track {
                        VStack(spacing: 4) {
                            Text(track.title)
                                .font(.system(size: fs(26), weight: .semibold))
                                .tracking(-0.3)
                            Text(track.artist)
                                .font(.system(size: fs(17)))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: side + 120)
                        .id(media.trackKey)
                        .transition(.opacity)
                    }
                    VStack(spacing: 14) {
                        ProgressBar(media: media)
                        HStack(spacing: 22) {
                            ControlButton(id: "fs.previous", symbol: "backward.fill", size: 20) { media.previous() }
                            ControlButton(id: "fs.playPause", symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 30) { media.playPause() }
                            ControlButton(id: "fs.next", symbol: "forward.fill", size: 20) { media.next() }
                        }
                    }
                    .frame(width: side)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.35), value: media.trackKey)
        .onExitCommand(perform: close)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func background(in size: CGSize) -> some View {
        ZStack {
            Color.black
            if let art = media.artwork, !reduceTransparency {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 80)
                    .saturation(1.3)
                    .opacity(0.75)
                    .clipped()
                    .id(media.trackKey)
                    .transition(.opacity)
            }
            // Keeps white text readable on light covers.
            Color.black.opacity(0.35)
        }
    }

    @ViewBuilder
    private func cover(side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.05, style: .continuous)
        Group {
            if let art = media.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.3, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
        .scaleEffect(media.isPlaying || reduceMotion ? 1 : 0.9)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: media.isPlaying)
        .contentShape(shape)
        .onTapGesture(perform: close)
        .accessibilityLabel("Album artwork. Click to close.")
    }
}

// MARK: - The lock screen's player card

/// While the Mac is locked and something is loaded in a music app: a player
/// card under the clock, like iPhone's lock screen. Click the artwork and it
/// fills the screen. Two windows of their own on the lock screen's layer,
/// separate from the island.
@MainActor
final class LockScreenPlayer {
    private let vm: NotchViewModel
    private let media: MediaController
    private var card: NSPanel?
    private var artwork: NSPanel?
    private var shownOn: NSRect?
    private var shownTransparency: Double?
    private var shownTextScale: CGFloat?

    /// Card size, and how high its bottom edge sits (a share of the screen's
    /// height): above the password field, below the clock.
    private static let cardSize = CGSize(width: 520, height: 600)
    private static let height: CGFloat = 0.24

    init(vm: NotchViewModel, media: MediaController) {
        self.vm = vm
        self.media = media
    }

    /// Called from the island's frequent check; cheap when nothing changes.
    func update(on screen: NSScreen, level: NSWindow.Level) {
        let locked = vm.lock.state == .locked
        let music = locked && vm.showOnLockScreen && vm.showsLockScreenPlayer && media.track != nil
        let activities = locked && vm.showOnLockScreen && vm.showsLockScreenActivities
            && vm.liveActivities.isEnabled && !vm.liveActivities.items.isEmpty
        let wanted = music || activities
        if wanted {
            if card == nil || shownOn != screen.frame || shownTransparency != vm.glassTransparency
                || shownTextScale != vm.textScale {
                showCard(on: screen, level: level)
            }
        } else {
            hide(&card)
        }
        let artWanted = music && vm.ui.showsArtworkFullScreen && media.playsFromMusicApp
        // The card steps aside while the artwork has the screen.
        if artWanted, artwork == nil {
            showArtwork(on: screen, level: level)
            card?.animator().alphaValue = 0
        } else if !artWanted, artwork != nil {
            hide(&artwork)
            card?.animator().alphaValue = 1
        }
        if !locked, vm.ui.showsArtworkFullScreen { vm.ui.showsArtworkFullScreen = false }
    }

    private func makeWindow(frame: NSRect, level: NSWindow.Level) -> NSPanel {
        NotchPanel.keepActiveGlass()
        let window = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false
        return window
    }

    private func showCard(on screen: NSScreen, level: NSWindow.Level) {
        hide(&card)
        let size = Self.cardSize
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                           y: (screen.frame.minY + screen.frame.height * Self.height).rounded(),
                           width: size.width, height: size.height)
        let window = makeWindow(frame: frame, level: level)
        let host = FirstMouseHostingView(rootView: LockScreenStack(vm: vm, media: media,
                                                                   tintOpacity: 1 - vm.glassTransparency) { [weak self] in
            self?.vm.ui.showsArtworkFullScreen = true
        }
        .environment(vm.ui)
        .environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        present(window)
        card = window
        shownOn = screen.frame
        shownTransparency = vm.glassTransparency
        shownTextScale = vm.textScale
    }

    private func showArtwork(on screen: NSScreen, level: NSWindow.Level) {
        let window = makeWindow(frame: screen.frame, level: level)
        let host = FirstMouseHostingView(rootView: FullScreenArtworkView(media: media) { [weak self] in
            self?.vm.ui.showsArtworkFullScreen = false
        }
        .environment(vm.ui)
        .environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        present(window)
        artwork = window
    }

    private func present(_ window: NSPanel) {
        window.alphaValue = 0
        window.orderFrontRegardless()
        _ = LockScreenSpace.add(window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            window.animator().alphaValue = 1
        }
    }

    private func hide(_ slot: inout NSPanel?) {
        guard let window = slot else { return }
        slot = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }
}

/// What the lock screen shows under the clock: Live Activities (up to two,
/// like iPhone), then the music card, stacked from the bottom.
struct LockScreenStack: View {
    let vm: NotchViewModel
    let media: MediaController
    let tintOpacity: Double
    let showArtwork: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if vm.showsLockScreenActivities, vm.liveActivities.isEnabled {
                ForEach(vm.liveActivities.items.prefix(2)) { activity in
                    LockActivityCard(activity: activity, tintOpacity: tintOpacity)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            if vm.showsLockScreenPlayer, media.track != nil {
                LockScreenPlayerCard(media: media, tintOpacity: tintOpacity, showArtwork: showArtwork)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.45, dampingFraction: 0.88), value: vm.liveActivities.items.map(\.id))
    }
}

/// A Live Activity on the lock screen, laid out like iPhone's: the app's
/// icon and name on top, the main line big in the app's colour, what's
/// happening under it, and the progress bar.
struct LockActivityCard: View {
    let activity: ExternalActivity
    let tintOpacity: Double

    private let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ExternalAppIcon(activity: activity, size: 26)
                Spacer(minLength: 8)
                Text(activity.appName)
                    .font(.system(size: fs(13), weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            switch activity.display {
            case .match(let match):
                HStack {
                    Text("\(match.home)  \(match.homeScore) – \(match.awayScore)  \(match.away)")
                        .font(.system(size: fs(18), weight: .bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 6)
                    if let minute = match.minute {
                        LiveMinute(minute: minute, live: !activity.isStale)
                            .font(.system(size: fs(15), weight: .bold).monospacedDigit())
                    }
                }
                if let competition = match.competition {
                    Text(competition).font(.system(size: fs(13))).foregroundStyle(Color.white.opacity(0.8)).lineLimit(1)
                }
            case .general(let general):
                HStack(alignment: .firstTextBaseline) {
                    Text(general.title)
                        .font(.system(size: fs(18), weight: .bold))
                        .foregroundStyle(general.isTask ? AnyShapeStyle(.primary) : AnyShapeStyle(activity.accent))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    if general.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: fs(18), weight: .semibold))
                            .foregroundStyle(activity.accent)
                    } else if general.isTask, general.progress != nil {
                        TaskProgress(general: general, size: 18, showsPercent: true)
                            .font(.system(size: fs(15), weight: .semibold))
                    } else if general.countdown != nil, let value = general.value {
                        ActivityValueText(text: value, countdown: general.countdown)
                            .font(.system(size: fs(18), weight: .bold))
                            .foregroundStyle(activity.accent)
                    }
                }
                if let subtitle = general.subtitle {
                    Text(subtitle)
                        .font(.system(size: fs(14)))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(2)
                }
                if !general.isTask, let progress = general.progress {
                    ActivityProgressBar(fraction: general.isComplete ? 1 : progress, tint: activity.accent, height: 7)
                        .padding(.top, 4)
                }
            }
        }
        .padding(18)
        .frame(width: fs(380), alignment: .leading)
        .opacity(activity.isStale ? 0.7 : 1)
        .foregroundStyle(.white)
        // The glass goes behind the card, not around its content: content
        // inside glass gets the glass's vibrancy, which on the lock screen
        // greys text out.
        .background { Color.clear.glassSurface(in: shape) }
        .environment(\.glassTintOpacity, tintOpacity)
    }
}

/// The card: artwork, song and artist, the progress line, and previous,
/// play/pause and next, on the same glass as the island.
struct LockScreenPlayerCard: View {
    let media: MediaController
    /// Settings > Transparency: 1 is solid black, 0 clear glass.
    let tintOpacity: Double
    let showArtwork: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

    var body: some View {
        Group {
            if let track = media.track {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        artwork
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: fs(14), weight: .semibold))
                            Text(track.artist)
                                .font(.system(size: fs(13)))
                                .foregroundStyle(Color.white.opacity(0.8))
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(media.trackKey)
                        .transition(.opacity)
                    }
                    ProgressBar(media: media)
                    HStack(spacing: 34) {
                        ControlButton(id: "ls.previous", symbol: "backward.fill", size: 18) { media.previous() }
                        ControlButton(id: "ls.playPause", symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 26) { media.playPause() }
                        ControlButton(id: "ls.next", symbol: "forward.fill", size: 18) { media.next() }
                    }
                }
                .padding(18)
                .frame(width: fs(380))
                .foregroundStyle(.white)
                // The island's own glass, at Settings > Transparency, behind
                // the content (inside it, the text would be greyed out).
                .background { Color.clear.glassSurface(in: shape) }
                .environment(\.glassTintOpacity, tintOpacity)
                .animation(.easeOut(duration: 0.3), value: media.trackKey)
            }
        }
    }

    private var artwork: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(Rectangle())
        // Only Apple Music's and Spotify's artwork fills the screen; from a
        // browser it's often a video still or the site's logo.
        .onTapGesture { if media.playsFromMusicApp { showArtwork() } }
        .help(media.playsFromMusicApp ? "Show the artwork full screen" : "")
        .accessibilityAddTraits(media.playsFromMusicApp ? .isButton : [])
        .accessibilityLabel(media.playsFromMusicApp ? "Album artwork. Click to fill the screen." : "Artwork")
    }
}

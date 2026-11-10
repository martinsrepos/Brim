import AppKit
import SwiftUI

// MARK: - Shared motion

/// Dynamic Island springs. The island is a living, physical object, so it
/// opens with a little give and settles back with less: the one place Apple's
/// own guidelines use bounce without a flick. Springs retarget from the current
/// on-screen value, so moving in and out mid-animation reverses without a jump.
private func notchMotion(expanded: Bool, reduceMotion: Bool) -> Animation {
    if reduceMotion { return .easeOut(duration: 0.18) }
    return expanded
        ? .spring(response: 0.46, dampingFraction: 0.74)
        : .spring(response: 0.4, dampingFraction: 0.86)
}

// MARK: - Island

/// The island (or, on a MacBook, the notch): dark Liquid Glass, from solid
/// black to clear depending on Settings > Transparency.
///
/// Two windows show this view: a normal one for everyday use (where glass can
/// sample and refract what's behind it), and a copy on the lock screen layer
/// that only appears while the Mac is locked.
struct IslandRootView: View {
    let vm: NotchViewModel
    let media: MediaController
    let alerts: AlertCenter
    let onLockScreen: Bool
    /// Set when islands show on several displays (see `NotchViewModel.mode(on:)`).
    var displayID: CGDirectDisplayID? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private var contentTransition: AnyTransition {
        reduceMotion ? .opacity : .notchContent
    }

    /// Exactly one of the two windows draws the island at any moment.
    private var isActiveWindow: Bool {
        // The lock screen window only while locked. The unlock plays in the
        // normal window, so its glass can fade in while the lock opens.
        if onLockScreen {
            return vm.lock.state == .locked && vm.showOnLockScreen
        }
        switch vm.lock.state {
        case .unlocked: return true
        case .unlocking: return vm.showOnLockScreen
        case .locked: return false
        }
    }

    var body: some View {
        let mode = vm.mode(on: displayID)
        let size = vm.size(for: mode)
        let radii = vm.radii(for: mode)
        let motion = notchMotion(expanded: mode == .expanded || mode == .prompter, reduceMotion: reduceMotion)
        let secondaryEntry = vm.secondaryEntry(for: mode)
        let secondary = secondaryEntry?.mode
        let tucked = vm.isTuckedAway(on: displayID, mode: mode)
        // Two activities: the pill gives up its right end to the circle. The
        // island keeps its place and width; one shape draws pill, neck and
        // circle, so black and glass both split as a single liquid object.
        let split = secondary != nil && vm.isIsland
        // A notch keeps its pill whole and grows an extra wing on the right.
        let notchSplit = secondary != nil && !vm.isIsland
        let pillWidth = size.width - (split ? vm.splitShrink : 0) - (notchSplit ? vm.notchExtension : 0)
        let bubbleEntry = secondaryEntry ?? vm.ui.bubbleEntry
        let h = vm.closedSize.height

        NotchSurface(isIsland: vm.isIsland,
                     radii: radii,
                     glass: vm.usesGlass(for: mode, onLockScreen: onLockScreen),
                     lifted: mode == .expanded || mode == .prompter,
                     split: split ? 1 : 0,
                     compactHeight: h,
                     splitGap: vm.bubbleGap) {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    // Tucked away over a full-screen app, nothing is drawn:
                    // no clock, waveform or rings running out of sight. It
                    // all comes back as the island drops down.
                    if !tucked {
                        content(for: mode)
                        sharedArtwork(for: mode, width: pillWidth)
                        // Part of the music pill: it comes and goes with the
                        // pill's own content (blur and fade), staying at the
                        // pill's bottom edge instead of sweeping down the panel.
                        if mode == .live {
                            musicProgressBand()
                                .transition(contentTransition)
                        }
                    }
                }
                .frame(width: pillWidth, height: size.height, alignment: .topLeading)
                // Island: green camera / orange microphone dots inside, top
                // center, where they stand out. They stay put as the island
                // changes shape.
                .overlay(alignment: .top) {
                    if vm.isIsland {
                        privacyDots(size: 5)
                            .padding(.top, max(3, (h * 0.13).rounded()))
                    }
                }

                // The circle's glyph, in the island's right end. Click it to
                // show the next activity when there are several.
                // Notch: the second activity in its own wing on the right,
                // past a hairline. Click it to swap, like the island's circle.
                if notchSplit, !tucked, let secondaryEntry {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: (h * 0.5).rounded())
                        .offset(x: pillWidth, y: (h * 0.25).rounded())
                        .transition(.opacity)
                    BubbleView(entry: secondaryEntry, vm: vm, media: media)
                        .frame(width: h, height: h)
                        .offset(x: pillWidth + ((vm.notchExtension - h) / 2).rounded())
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }

                if vm.isIsland, !tucked, let bubbleEntry {
                    // Grows with the circle on the same spring (the circle
                    // starts at half size too), so they arrive together.
                    BubbleView(entry: bubbleEntry, vm: vm, media: media)
                        .frame(width: h, height: h)
                        .scaleEffect(split ? 1 : 0.5)
                        .opacity(split ? 1 : 0)
                        .offset(x: size.width - h)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .padding(.horizontal, radii.top)
        }
        // Remember what was in the circle, so it can melt back into the pill
        // with its glyph still showing after the activity ends.
        .onChange(of: vm.secondaryEntry(for: vm.mode)) { _, newValue in
            if let newValue { vm.ui.bubbleEntry = newValue }
        }
        // Notch: inside the black, just right of the camera housing (the
        // notch grows a little for them when idle). A notch drawn on a screen
        // without one has no camera, so they sit at its top center.
        // The open panel has buttons up there, so it puts the dots in its
        // header row instead, where they take their own place.
        .overlay(alignment: .top) {
            if !vm.isIsland && mode != .expanded {
                let count = CGFloat((vm.showPrivacyDots && vm.cameraDotOn ? 1 : 0)
                                    + (vm.showPrivacyDots && vm.micDotOn ? 1 : 0))
                let dotsWidth = count * PrivacyDots.defaultSize + max(0, count - 1) * 4
                privacyDots(size: PrivacyDots.defaultSize)
                    .offset(x: vm.hasNotch ? vm.cameraGap / 2 + 2 + dotsWidth / 2 - vm.shapeShift(for: mode) : 0,
                            y: vm.hasNotch ? ((vm.closedSize.height - PrivacyDots.defaultSize) / 2).rounded() : 5)
            }
        }
        // A notch with a second activity grows to the right only.
        .offset(x: vm.shapeShift(for: mode))
        .opacity(vm.isHiddenWhenIdle(mode) ? 0 : 1)
        .padding(.top, vm.topInset)
        // Full screen: slide up out of view (and back down when revealed),
        // the same path in and out.
        .offset(y: tucked ? -(vm.topInset + size.height + 24) : 0)
        .opacity(tucked ? 0 : 1)
        .environment(vm.ui)
        // Always dark: white text on black-tinted glass, in light mode too.
        .environment(\.colorScheme, .dark)
        .environment(\.glassTintOpacity, vm.glassTintOpacity)
        // Text Size: font sizes come from a plain value, so a change redraws
        // the island from scratch.
        .id(vm.textScale)
        .frame(width: NotchViewModel.canvas.width, height: NotchViewModel.canvas.height, alignment: .top)
        .ignoresSafeArea()
        .animation(motion, value: mode)
        .animation(motion, value: alerts.current?.id)
        .animation(motion, value: vm.closedSize)
        // Keep Awake from the menu bar: the cup pops into the idle pill (and
        // the pill widens if it was empty) with the same motion.
        .animation(motion, value: vm.keepAwake.isOn)
        .animation(motion, value: vm.showsIdleContent)
        .animation(motion, value: vm.lock.state)
        .animation(motion, value: tucked)
        // Splitting gets a livelier spring, so the circle pops free.
        .animation(reduceMotion ? motion : .spring(response: 0.6, dampingFraction: 0.58),
                   value: secondaryEntry)
        // Outside the animations on purpose: the hand-off between the two
        // windows is instant, so the island never looks doubled or faded.
        .opacity(isActiveWindow ? 1 : 0)
    }

    private func privacyDots(size: CGFloat) -> some View {
        PrivacyDots(camera: vm.showPrivacyDots && vm.cameraDotOn,
                    microphone: vm.showPrivacyDots && vm.micDotOn,
                    size: size)
            .animation(.easeOut(duration: 0.2), value: vm.cameraDotOn)
            .animation(.easeOut(duration: 0.2), value: vm.micDotOn)
    }

    /// The music pill's progress: a faint band along the pill's bottom edge,
    /// coming and going with the pill's content.
    @ViewBuilder
    private func musicProgressBand() -> some View {
        if let duration = media.track?.duration, duration > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PillProgressBar(progress: media.position(at: context.date) / duration, color: media.accent)
            }
            .frame(height: vm.closedSize.height, alignment: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }

    /// The album artwork lives outside the per-state content, so SwiftUI keeps
    /// one view and springs its position, size and corners from the pill to the
    /// panel. The pill and the panel only leave an empty spot for it.
    @ViewBuilder
    private func sharedArtwork(for mode: NotchMode, width: CGFloat) -> some View {
        if let place = vm.artworkPlacement(for: mode) {
            let paused = mode == .expanded && !media.isPlaying && !reduceMotion
            // A new song swipes in across the artwork, like a card carousel.
            ZStack {
                ArtworkView(image: media.artwork, size: place.size, corner: place.corner)
                    .id(media.trackKey)
                    .transition(trackSwipe)
            }
            .frame(width: place.size, height: place.size)
            .clipShape(RoundedRectangle(cornerRadius: place.corner, style: .continuous))
            .animation(trackSwipeAnimation, value: media.trackKey)
            .shadow(color: media.accent.opacity(mode == .expanded && media.isPlaying ? 0.35 : 0), radius: 10)
            // Sits back a little when paused, like Apple Music.
            .scaleEffect(paused ? 0.92 : 1)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: paused)
            // In the panel, clicking the artwork opens the app that's playing.
            .contentShape(Rectangle())
            .onTapGesture {
                guard mode == .expanded else { return }
                media.openSourceApp()
            }
            .offset(x: place.x, y: place.y)
            // Flying from the pill it's the same view and just moves; arriving
            // fresh (music was in the circle) it enters like the panel's content.
            // The offset only moves the drawing, so the grow point is given in
            // the unmoved frame: the island's top center, the same point the
            // rest of the panel grows from (not the artwork's own corner).
            .transition(reduceMotion ? .opacity
                        : .notchContentGrowing(from: UnitPoint(x: width / 2 / max(place.size, 1), y: 0)))
        }
    }

    private var trackSwipe: AnyTransition {
        songSwipe(forward: media.trackDirection > 0, layout: layoutDirection, reduceMotion: reduceMotion)
    }

    private var trackSwipeAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.88)
    }

    @ViewBuilder
    private func content(for mode: NotchMode) -> some View {
        switch mode {
        case .idle:
            if vm.showsIdleContent {
                IdleClockView(height: vm.closedSize.height, fontSize: (vm.closedSize.height * 0.43).rounded(),
                              showsClock: vm.showClock,
                              weather: vm.showWeather ? vm.weather.now : nil,
                              keepsAwake: vm.keepAwake.isOn,
                              cameraGap: vm.idleUsesWings ? vm.cameraGap : 0)
                    .transition(contentTransition)
            } else {
                Color.clear
            }
        case .timer:
            TimerActivityView(timer: vm.timer, itemID: vm.pillTimerID, notchWidth: vm.cameraGap,
                              height: vm.closedSize.height, layout: vm.compactLayout,
                              showsTitle: vm.showsTitleWhenCompact)
                .transition(contentTransition)
        case .event:
            if let event = vm.upcomingEvent {
                EventActivityView(event: event, minutes: vm.calendar.minutesUntil(event),
                                  notchWidth: vm.cameraGap, height: vm.closedSize.height,
                                  layout: vm.compactLayout, showsTitle: vm.showsTitleWhenCompact)
                    .transition(contentTransition)
            }
        case .call:
            if let call = vm.currentCall {
                CallActivityView(call: call, isMuted: vm.callIsMuted, voice: vm.callVoice,
                                 live: !vm.demo.isRunning,
                                 notchWidth: vm.cameraGap, height: vm.closedSize.height,
                                 layout: vm.compactLayout, showsTitle: vm.showsTitleWhenCompact)
                    .transition(contentTransition)
            }
        case .reminder:
            if let reminder = vm.upcomingReminder {
                ReminderActivityView(reminder: reminder, minutes: vm.reminders.minutesUntil(reminder),
                                     notchWidth: vm.cameraGap, height: vm.closedSize.height,
                                     layout: vm.compactLayout, showsTitle: vm.showsTitleWhenCompact)
                    .transition(contentTransition)
            }
        case .download:
            if let download = vm.currentDownload {
                DownloadActivityView(download: download, notchWidth: vm.cameraGap,
                                     height: vm.closedSize.height, layout: vm.compactLayout,
                                     showsTitle: vm.showsTitleWhenCompact)
                    .transition(contentTransition)
            }
        case .external:
            if let activity = vm.liveActivities.item(vm.pillExternalID) {
                ExternalActivityView(activity: activity, notchWidth: vm.cameraGap, height: vm.closedSize.height,
                                     layout: vm.compactLayout, showsTitle: vm.showsTitleWhenCompact)
                    .id(activity.id)
                    .transition(contentTransition)
            }
        case .live:
            LiveActivityView(media: media, notchWidth: vm.cameraGap, height: vm.closedSize.height,
                             layout: vm.compactLayout, showsTitle: vm.showsTitleWhenCompact)
                .transition(contentTransition)
        case .locked, .unlocking:
            // One case for both, so SwiftUI keeps the same view and the lock
            // symbol morphs open instead of being swapped out.
            LockActivityView(isOpen: mode == .unlocking && vm.lock.isOpen, height: vm.closedSize.height,
                             layout: vm.compactLayout, centered: vm.isIsland)
                .transition(contentTransition)
        case .banner:
            if let alert = alerts.current {
                BannerView(alert: alert, topInset: vm.contentTopInset, hidesPreview: vm.hidesPreviews)
                    // A click (no drag) opens what it's about: the app that
                    // sent it, the downloaded file, or its action.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if alerts.openFromBanner(alert) { vm.ui.bannerClicked = true }
                    }
                    .id(alert.id)
                    .transition(contentTransition)
            }
        case .expanded:
            ExpandedView(vm: vm, media: media, alerts: alerts, layout: vm.panelLayout)
                .transition(contentTransition)
        case .prompter:
            PrompterView(prompter: vm.prompter, size: vm.size(for: .prompter), topInset: vm.contentTopInset) {
                if let script = vm.prompter.script { vm.openScript(script) }
            }
                .transition(contentTransition)
        }
    }
}

// MARK: - Surface

/// The shape and its material. A floating capsule / rounded rectangle on screens
/// without a notch (which can split into pill + circle); a notch flared into the
/// top edge on a MacBook.
///
/// Black and glass are two layers that crossfade while the shape springs to its
/// new size, so switching material mid-morph stays one continuous object.
struct NotchSurface<Content: View>: View {
    let isIsland: Bool
    let radii: NotchRadii
    let glass: Bool
    let lifted: Bool
    /// 0 = one pill, 1 = pill + circle (island only).
    var split: CGFloat = 0
    var compactHeight: CGFloat = 0
    var splitGap: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        if isIsland {
            IslandSurface(corner: radii.bottom, split: split, compactHeight: compactHeight,
                          gap: splitGap, glass: glass, lifted: lifted, content: content)
        } else {
            SurfaceBody(shape: NotchShape(topRadius: radii.top, bottomRadius: radii.bottom),
                        glass: glass, lifted: lifted, isIsland: false, content: content)
        }
    }
}

/// The island's outline animates through this view rather than through the
/// shape: each frame builds a plain shape from the current corner radius and
/// split, so the glass material always gets the exact in-between outline.
private struct IslandSurface<Content: View>: View, Animatable {
    var corner: CGFloat
    var split: CGFloat
    let compactHeight: CGFloat
    let gap: CGFloat
    let glass: Bool
    let lifted: Bool
    let content: Content

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(corner, split) }
        set {
            corner = newValue.first
            split = newValue.second
        }
    }

    var body: some View {
        SurfaceBody(shape: IslandShape(corner: corner, split: split, compactHeight: compactHeight, gap: gap),
                    glass: glass, lifted: lifted, isIsland: true, content: content)
    }
}

private struct SurfaceBody<S: Shape, Content: View>: View {
    let shape: S
    let glass: Bool
    let lifted: Bool
    let isIsland: Bool
    let content: Content

    var body: some View {
        content
            .environment(\.colorScheme, .dark)
            .background {
                ZStack {
                    Color.clear
                        .glassSurface(in: shape)
                        .opacity(glass ? 1 : 0)
                    shape.fill(Color.black)
                        .opacity(glass ? 0 : 1)
                }
            }
            .clipShape(shape)
            // A floating object casts a shadow; deeper when it grows.
            .shadow(color: Color.black.opacity(lifted ? 0.4 : (isIsland ? 0.22 : 0)),
                    radius: lifted ? 16 : 5, y: lifted ? 8 : 2)
    }
}

/// The island's outline: a rounded rectangle (a capsule when compact) and,
/// while split, a circle in its right end joined by a liquid neck. All one
/// path, so glass renders it as a single piece with no seams or overlaps.
struct IslandShape: Shape {
    var corner: CGFloat
    var split: CGFloat
    let compactHeight: CGFloat
    let gap: CGFloat

    func path(in rect: CGRect) -> Path {
        let shrink = (gap + compactHeight) * split
        let pillRect = CGRect(x: rect.minX, y: rect.minY,
                              width: max(compactHeight, rect.width - shrink), height: rect.height)
        let radius = min(corner, pillRect.height / 2, pillRect.width / 2)
        let pill = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: pillRect)
        guard split > 0.001, compactHeight > 0 else { return pill }

        // The circle sits where the pill's right end was. It starts small inside
        // that end and grows to full size as the pill pulls back.
        let r = compactHeight / 2
        let bubbleRadius = r * (0.5 + 0.5 * split)
        let bubble = CGPoint(x: rect.maxX - r, y: rect.minY + r)
        let cap = CGPoint(x: pillRect.maxX - r, y: rect.minY + r)
        let circle = Path(ellipseIn: CGRect(x: bubble.x - bubbleRadius, y: bubble.y - bubbleRadius,
                                            width: bubbleRadius * 2, height: bubbleRadius * 2))
        let neck = SplitNeck(pillCenter: cap, pillRadius: r, bubbleCenter: bubble,
                             bubbleRadius: bubbleRadius, reach: compactHeight + gap * 0.6)
            .path(in: rect)

        // Each piece is merged separately so their directions can't cancel out.
        var outline = pill.cgPath.union(circle.cgPath)
        if !neck.isEmpty { outline = outline.union(neck.cgPath) }
        return Path(outline)
    }
}

extension View {
    /// Liquid Glass on macOS 26+, a vibrant blur on earlier versions, and a solid
    /// surface when Reduce Transparency is on.
    func glassSurface<S: Shape>(in shape: S) -> some View {
        modifier(GlassSurface(shape: shape))
    }
}

/// Dark glass with a layer of black over it (Settings > Transparency), from
/// solid black to clear.
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @Environment(\.glassTintOpacity) private var tintOpacity

    /// Drawn as a layer over the glass, because Liquid Glass's own tint keeps
    /// it bright.
    private var darkening: Color {
        scheme == .dark ? Color.black.opacity(tintOpacity) : Color.clear
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.stroke(Color.primary.opacity(0.15), lineWidth: 1))
                .clipShape(shape)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                // Apple's clear Liquid Glass (the least frosted kind), with a
                // black veil inside it for Settings > Transparency. The veil
                // stops just short of the edge and fades into it, so the
                // glass's rim, where it bends and catches the light, stays
                // visible all the way to solid black.
                let darkness = scheme == .dark ? tintOpacity : 0
                content
                    .glassEffect(.clear, in: shape)
                    // The glass picks its light or dark rendering from here.
                    .environment(\.colorScheme, scheme)
                    .overlay(GlassVeil(shape: shape, darkness: darkness).allowsHitTesting(false))
            } else {
                blurred(content)
            }
            #else
            blurred(content)
            #endif
        }
    }

    private func blurred(_ content: Content) -> some View {
        content
            .background(shape.fill(darkening))
            .background(VisualEffectBackdrop(dark: scheme == .dark).clipShape(shape))
            // A bright hairline on the edge reads as light catching the material.
            .overlay(shape.stroke(Color.white.opacity(scheme == .dark ? 0.18 : 0.4), lineWidth: 0.5))
            .clipShape(shape)
    }
}

/// The black inside the glass. Clear glass needs some dimming behind white
/// text (Apple says as much), so even "clear" keeps a light smoke; from
/// there it deepens to solid black. While it's see-through, the veil stops
/// short of the edge, so the rim keeps its lens; towards black the gap
/// closes, and at solid black there's no frame at all, like Dynamic Island.
private struct GlassVeil<S: Shape>: View {
    let shape: S
    /// Settings > Transparency: 0 clear, 1 solid black.
    let darkness: Double

    private var opacity: Double { 0.32 + 0.68 * darkness }
    private var rim: Double { max(0, 1 - darkness * 1.25) }

    var body: some View {
        ZStack {
            shape.fill(Color.black)
            shape.stroke(Color.black, lineWidth: 3)
                .blur(radius: 1)
                .opacity(rim)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .clipShape(shape)
        .opacity(opacity)
    }
}

/// AppKit's behind-window blur, used before Liquid Glass existed. Follows the
/// system's light or dark appearance.
private struct VisualEffectBackdrop: NSViewRepresentable {
    let dark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

private struct GlassTintKey: EnvironmentKey {
    static let defaultValue: Double = 0.5
}

extension EnvironmentValues {
    /// How strongly Liquid Glass is tinted (Settings > Transparency).
    var glassTintOpacity: Double {
        get { self[GlassTintKey.self] }
        set { self[GlassTintKey.self] = newValue }
    }
}

// MARK: - Transitions

private struct BlurOpacity: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

extension AnyTransition {
    /// The outgoing content blurs away fast while the shape starts to grow; the
    /// incoming content follows a beat later, growing from the top. They never
    /// fight for attention, which is most of what makes the iPhone morph feel
    /// like one object. Never from zero scale.
    static var notchContent: AnyTransition { notchContentGrowing(from: .top) }

    /// The same, growing from a given point, so a view placed with an offset
    /// can grow from the panel's top center like everything else.
    static func notchContentGrowing(from anchor: UnitPoint) -> AnyTransition {
        .asymmetric(
            insertion: AnyTransition.modifier(active: BlurOpacity(radius: 6, opacity: 0),
                                              identity: BlurOpacity(radius: 0, opacity: 1))
                .combined(with: .scale(scale: 0.92, anchor: anchor))
                .animation(.spring(response: 0.4, dampingFraction: 0.9).delay(0.07)),
            removal: AnyTransition.modifier(active: BlurOpacity(radius: 6, opacity: 0),
                                            identity: BlurOpacity(radius: 0, opacity: 1))
                .combined(with: .scale(scale: 0.96, anchor: anchor))
                .animation(.easeOut(duration: 0.12))
        )
    }
}

// MARK: - Two activities at once

/// The second activity, in its circle, like iPhone's minimal presentation.
/// Timers and meetings show a short time ("12m", "9:59") inside a ring that
/// runs along the circle's edge; reminders show the Reminders icon.
///
/// Clicking it swaps it into the pill (with three or more, the next one moves
/// into the circle; small dots say how many). Hovering it doesn't open the
/// panel, so it can be clicked; hover the pill for everything in full.
struct BubbleView: View {
    let entry: ActivityEntry
    let vm: NotchViewModel
    let media: MediaController
    private var mode: NotchMode { entry.mode }
    @Environment(NotchUIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let h = vm.closedSize.height
        let all = vm.activityEntries
        ZStack {
            glyph(height: h)
                .id(entry)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            // Three or more: dots say how many, and which one the circle holds.
            if all.count > 2 {
                // Just inside the progress ring, not on it: on the ring they
                // made the bottom look heavier and the middle look off center.
                PageDots(count: all.count, current: all.firstIndex(of: entry) ?? 0)
                    .padding(.bottom, (h * 0.13 + 2).rounded())
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: h, height: h)
        .contentShape(Circle())
        .onTapGesture { vm.swapActivities() }
    }

    @ViewBuilder
    private func glyph(height h: CGFloat) -> some View {
        let font = Font.system(size: (h * 0.25).rounded(), weight: .semibold).monospacedDigit()
        switch mode {
        case .timer:
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let item = vm.timer.item(entry.timerID)
                let tint = (item?.kind ?? .timer).tint
                ZStack {
                    if item?.kind == .stopwatch {
                        StopwatchDial(elapsed: item?.elapsed(at: context.date) ?? 0, tint: tint)
                    } else {
                        EdgeRing(progress: item?.progress(at: context.date) ?? 0, tint: tint)
                    }
                    Text(item?.shortDisplay(at: context.date) ?? "0:00")
                        .font(font)
                        .foregroundStyle(tint.opacity(item?.isPaused == true ? 0.55 : 1))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, h * 0.14)
                }
            }
        case .event:
            if let event = vm.upcomingEvent {
                let minutes = vm.calendar.minutesUntil(event)
                let now = minutes <= 0.5
                ZStack {
                    // Fills as the meeting gets closer; green once it starts.
                    EdgeRing(progress: max(0, 1 - minutes / 15), tint: now ? .green : event.color)
                    if now {
                        Image(systemName: event.joinURL != nil ? "video.fill" : "calendar")
                            .font(.system(size: (h * 0.32).rounded(), weight: .semibold))
                            .foregroundStyle(Color.green)
                    } else {
                        Text("\(Int(minutes.rounded(.up)))m")
                            .font(font)
                            .foregroundStyle(event.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
            }
        case .download:
            if let download = vm.currentDownload {
                ZStack {
                    EdgeRing(progress: download.fraction, tint: .blue)
                    Image(systemName: download.symbol)
                        .font(.system(size: (h * 0.34).rounded(), weight: .bold))
                        .foregroundStyle(Color.blue)
                }
            }
        case .reminder:
            ReminderIcon()
                .frame(width: (h * 0.66).rounded(), height: (h * 0.66).rounded())
        case .call:
            if let call = vm.currentCall {
                // A green ring and the call's length; a red slashed mic when muted.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ZStack {
                        EdgeRing(progress: 1, tint: vm.callIsMuted ? .red : .green)
                        if vm.callIsMuted {
                            Image(systemName: "mic.slash.fill")
                                .font(.system(size: (h * 0.34).rounded(), weight: .semibold))
                                .foregroundStyle(Color.red)
                        } else {
                            Text(shortClock(context.date.timeIntervalSince(call.started)))
                                .font(font)
                                .foregroundStyle(Color.green)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, h * 0.14)
                        }
                    }
                }
            }
        case .external:
            // The score (or the value) with the match's minute, or the app's
            // progress, around the edge.
            if let activity = vm.liveActivities.item(entry.externalID) {
                ZStack {
                    // A live match's ring breathes, softly: live, without a
                    // dot that could pass for the camera or recording light.
                    if let end = activity.countdown, !activity.isStale {
                        // A countdown: the ring empties as the time runs
                        // out, in the app's colour (Duolingo's red).
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let total = max(1, end.timeIntervalSince(activity.started))
                            EdgeRing(progress: min(1, max(0, end.timeIntervalSince(context.date) / total)),
                                     tint: activity.accent)
                        }
                    } else {
                        LiveRing(progress: activity.progress ?? 1,
                                 tint: activity.isStale ? .secondary : (activity.isLiveMatch || activity.isMatch ? .green : activity.accent),
                                 breathing: activity.isLiveMatch)
                    }
                    if case .general(let general) = activity.display, !general.isComplete, !general.isTask || activity.short == nil {
                        // The app's icon inside the ring of its progress.
                        ExternalAppIcon(activity: activity, size: (h * 0.42).rounded())
                    } else if case .general(let general) = activity.display, general.isComplete {
                        // Finished: a tick in the full ring.
                        Image(systemName: "checkmark")
                            .font(.system(size: (h * 0.32).rounded(), weight: .bold))
                            .foregroundStyle(Color.green)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else if let short = activity.short {
                        ActivityValueText(text: short, countdown: activity.countdown)
                            .font(font)
                            .foregroundStyle(activity.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, h * 0.14)
                    } else {
                        ExternalAppIcon(activity: activity, size: (h * 0.42).rounded())
                    }
                }
            }
        case .live:
            // The song's progress runs around the edge, like the timer's.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let duration = media.track?.duration ?? 0
                let progress = duration > 0 ? media.position(at: context.date) / duration : 0
                // A little smaller with the page dots below it, so they fit
                // inside the ring.
                let size = (h * (vm.activityEntries.count > 2 ? 0.5 : 0.56)).rounded()
                ZStack {
                    EdgeRing(progress: progress, tint: media.accent)
                        .animation(.linear(duration: 1), value: progress)
                    ArtworkView(image: media.artwork, size: size, corner: size / 2)
                }
            }
        default:
            EmptyView()
        }
    }
}

/// A progress ring just inside the circle's edge. `nil` spins (unknown progress).
private struct EdgeRing: View {
    let progress: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let line = max(1.5, (geo.size.width * 0.07).rounded())
            let inset = line / 2 + max(1.5, geo.size.width * 0.06)
            ZStack {
                Circle().inset(by: inset).stroke(tint.opacity(0.22), lineWidth: line)
                if let progress {
                    Circle()
                        .inset(by: inset)
                        .trim(from: 0, to: max(0.02, min(progress, 1)))
                        .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    TimelineView(.animation) { context in
                        Circle()
                            .inset(by: inset)
                            .trim(from: 0, to: 0.3)
                            .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 360))
                    }
                }
            }
        }
    }
}

/// A stopwatch face: dashes round the edge like a watch's seconds track.
/// They light up one by one as the seconds tick (one dash per two seconds,
/// the newest half-lit on the odd second) and start over each minute.
struct StopwatchDial: View {
    let elapsed: TimeInterval
    let tint: Color
    private static let dashes = 30

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = side / 2 - max(1, side * 0.05)
            let length = max(1.5, side * 0.08)
            let width = max(0.75, side * 0.03)
            let seconds = Int(elapsed) % 60
            let lit = seconds / 2
            for index in 0..<Self.dashes {
                let angle = CGFloat(index) / CGFloat(Self.dashes) * 2 * .pi - .pi / 2
                let from = CGPoint(x: center.x + cos(angle) * (outer - length), y: center.y + sin(angle) * (outer - length))
                let to = CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                let opacity: Double = index < lit ? 1 : (index == lit && seconds % 2 == 1 ? 0.55 : 0.2)
                context.stroke(path, with: .color(tint.opacity(opacity)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Which of several activities the circle is showing.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(Color.primary.opacity(index == current ? 0.9 : 0.3))
                    .frame(width: 2.5, height: 2.5)
            }
        }
    }
}

/// The liquid bridge between the pill's rounded end and the circle: the
/// classic metaball connector (two circles joined by curves tangent to both).
/// It pinches thinner as they pull apart and is gone before the circle
/// settles, so at rest they're two clean shapes, like iPhone.
private struct SplitNeck: Shape {
    let pillCenter: CGPoint
    let pillRadius: CGFloat
    let bubbleCenter: CGPoint
    let bubbleRadius: CGFloat
    /// Center distance where the neck breaks.
    let reach: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c1 = pillCenter, c2 = bubbleCenter
        let r1 = pillRadius, r2 = bubbleRadius
        let d = hypot(c2.x - c1.x, c2.y - c1.y)
        // Fully inside the cap, or already apart: nothing to draw.
        guard r1 > 0, r2 > 0, d > abs(r1 - r2), d < reach else { return path }

        func clampedAcos(_ x: CGFloat) -> CGFloat { acos(min(1, max(-1, x))) }
        var u1: CGFloat = 0, u2: CGFloat = 0
        if d < r1 + r2 {
            u1 = clampedAcos((r1 * r1 + d * d - r2 * r2) / (2 * r1 * d))
            u2 = clampedAcos((r2 * r2 + d * d - r1 * r1) / (2 * r2 * d))
        }
        // How wide the neck meets the circles: full while they overlap, then
        // easing to a point as the gap opens toward `reach`.
        let touch = r1 + r2
        let t = d <= touch ? 0 : min(1, (d - touch) / max(0.001, reach - touch))
        let v = 0.5 * (1 - t * t * (3 - 2 * t))

        let angle = atan2(c2.y - c1.y, c2.x - c1.x)
        let spread = clampedAcos((r1 - r2) / d)
        let a1 = angle + u1 + (spread - u1) * v
        let a2 = angle - u1 - (spread - u1) * v
        let a3 = angle + .pi - u2 - (.pi - u2 - spread) * v
        let a4 = angle - .pi + u2 + (.pi - u2 - spread) * v

        func point(_ c: CGPoint, _ a: CGFloat, _ length: CGFloat) -> CGPoint {
            CGPoint(x: c.x + length * cos(a), y: c.y + length * sin(a))
        }
        let p1 = point(c1, a1, r1), p2 = point(c1, a2, r1)
        let p3 = point(c2, a3, r2), p4 = point(c2, a4, r2)

        // Handle length: shorter as the shapes separate, so the curves stay tight.
        let handle = min(v * 2.4, hypot(p3.x - p1.x, p3.y - p1.y) / touch) * min(1, d * 2 / touch)
        let h1 = point(p1, a1 - .pi / 2, r1 * handle)
        let h2 = point(p2, a2 + .pi / 2, r1 * handle)
        let h3 = point(p3, a3 + .pi / 2, r2 * handle)
        let h4 = point(p4, a4 - .pi / 2, r2 * handle)

        // The straight edges run through the circles' insides, which are drawn
        // on top in the same black, so only the curved sides show.
        path.move(to: p1)
        path.addCurve(to: p3, control1: h1, control2: h3)
        path.addLine(to: p4)
        path.addCurve(to: p2, control1: h4, control2: h2)
        path.closeSubpath()
        return path
    }
}

/// The song-change swipe, in screen terms whatever the Mac's language: Next
/// brings the new song in from the left, moving right; Previous from the
/// right, moving left. (SwiftUI's "leading" is the right edge in Arabic or
/// Hebrew, so the edge is picked from the layout direction.)
func songSwipe(forward: Bool, layout: LayoutDirection, reduceMotion: Bool) -> AnyTransition {
    if reduceMotion { return .opacity }
    let fromLeft = forward
    let edge: Edge = fromLeft == (layout == .leftToRight) ? .leading : .trailing
    return .push(from: edge)
}

// MARK: - Live activity (collapsed, music playing)

struct LiveActivityView: View {
    let media: MediaController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let notchWidth: CGFloat
    let height: CGFloat
    let layout: CompactLayout
    /// Island: artwork, title and artist, equalizer. Notch: the camera is in the
    /// middle, so only artwork and equalizer fit, one on each side.
    var showsTitle = false

    var body: some View {
        HStack(spacing: 8) {
            // The artwork itself is drawn by the island (it flies into the panel);
            // this keeps its spot, centered in the pill's rounded end.
            Color.clear.frame(width: layout.artworkSize, height: layout.artworkSize)
            if showsTitle, let track = media.track {
                // Next song: the new title comes in from the left, moving right.
                // Previous: from the right, moving left.
                ZStack(alignment: .leading) {
                    // Song on top, artist under it in a smaller size, both
                    // fitted to the pill's height.
                    let titleSize = min(14, max(10.5, (height * 0.37).rounded()))
                    VStack(alignment: .leading, spacing: -1) {
                        Text(track.title)
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundStyle(media.isPlaying ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                        if !track.artist.isEmpty {
                            Text(track.artist)
                                .font(.system(size: (titleSize * 0.8).rounded()))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(media.trackKey)
                    .transition(songSwipe(forward: media.trackDirection > 0, layout: layoutDirection, reduceMotion: reduceMotion))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.88),
                           value: media.trackKey)
                // The title dims and brightens with a short fade on pause / play.
                .animation(.easeInOut(duration: 0.35), value: media.isPlaying)
            } else {
                Spacer(minLength: notchWidth)
            }
            // Bouncing bars when playing, a row of dots when paused. Centered in the other end.
            EqualizerView(color: media.accent, isPlaying: media.isPlaying)
                .frame(width: layout.equalizerSize, height: layout.equalizerSize)
        }
        .padding(.leading, layout.artworkInset)
        .padding(.trailing, layout.trailingInset)
        .frame(height: height)
    }
}

/// The compact music pill's progress: the bottom few points of the pill,
/// full width, faint.
struct PillProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(color.opacity(0.1))
                Rectangle()
                    .fill(color.opacity(0.42))
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
                    .animation(.linear(duration: 1), value: progress)
            }
        }
        .frame(height: 5.5)
        .accessibilityHidden(true)
    }
}

/// The playing indicator: the six bars of Apple's "waveform" SF Symbol, in
/// its proportions and resting heights, bouncing while music plays. Paused,
/// each bar shrinks to a round dot; playing lifts them back up.
///
/// SF Symbols can't move a bar's height (their animations only light up,
/// pulse or bounce the whole part), so the bars are drawn to match the
/// symbol rather than taken from it.
struct EqualizerView: View {
    var color: Color
    var isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WaveformBars(color: color, isPlaying: isPlaying, moving: !reduceMotion)
            .accessibilityHidden(true)
    }
}

/// The bars as Core Animation layers. macOS moves them on its own, on the
/// graphics side, so a song or a video playing costs Brim next to nothing:
/// drawn by SwiftUI 20 times a second, the same bars (and the glass around
/// them) cost about 10% of a core.
private struct WaveformBars: NSViewRepresentable {
    let color: Color
    let isPlaying: Bool
    /// False with Reduce Motion: the symbol's still shape instead of movement.
    let moving: Bool

    func makeNSView(context: Context) -> WaveformBarsView { WaveformBarsView() }

    func updateNSView(_ view: WaveformBarsView, context: Context) {
        view.update(color: NSColor(color), playing: isPlaying, moving: moving)
    }
}

/// `playing` false is the row of dots; true, each bar bounces between a third
/// of its height and a little above it, around the symbol's shape, each at
/// its own pace. Play and pause spring between the two.
final class WaveformBarsView: NSView {
    /// The "waveform" symbol's bar heights, tallest = 1.
    private static let rest: [CGFloat] = [0.24, 0.6, 1.0, 0.48, 0.74, 0.31]
    /// Bar width to gap, as in the symbol.
    private static let barToGap: CGFloat = 0.75

    private var bars: [CALayer] = []
    private var playing = false
    private var moving = true
    private var laidOut: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in Self.rest {
            let bar = CALayer()
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(color: NSColor, playing: Bool, moving: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.backgroundColor = color.cgColor }
        CATransaction.commit()
        guard playing != self.playing || moving != self.moving else { return }
        self.playing = playing
        self.moving = moving
        apply(animated: true)
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        apply(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        laidOut = .zero
        needsLayout = true
    }

    /// Places the bars on whole pixels (every bar exactly as wide as the
    /// others) and sets them moving or settling.
    private func apply(animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = bounds.width, height = bounds.height
        let count = CGFloat(Self.rest.count)
        let unit = width / (count + (count - 1) / Self.barToGap)
        let bar = max(2 / scale, (unit * scale).rounded(.down) / scale)
        let gap = max(1 / scale, ((bar / Self.barToGap) * scale).rounded() / scale)
        let used = bar * count + gap * (count - 1)
        let inset = (((width - used) / 2) * scale).rounded(.down) / scale
        let now = CACurrentMediaTime()

        for (i, layer) in bars.enumerated() {
            let rest = Self.rest[i]
            let low = max(bar, height * rest * 0.35)
            let high = max(bar, height * min(1, rest * 1.15))
            // Paused, each bar is exactly as tall as it is wide: a round dot.
            let target = playing ? (moving ? (low + high) / 2 : max(bar, height * rest)) : bar
            let current = (layer.presentation() ?? layer).bounds.height

            layer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.cornerRadius = bar / 2
            layer.position = CGPoint(x: inset + CGFloat(i) * (bar + gap) + bar / 2, y: height / 2)
            layer.bounds = CGRect(x: 0, y: 0, width: bar, height: target)
            CATransaction.commit()

            var settleTime: CFTimeInterval = 0
            if animated && abs(current - target) > 0.1 {
                let settle = CASpringAnimation(keyPath: "bounds.size.height")
                settle.fromValue = current
                settle.toValue = target
                settle.mass = 1
                settle.stiffness = 110
                settle.damping = 19
                settle.duration = min(settle.settlingDuration, 0.6)
                layer.add(settle, forKey: "settle")
                settleTime = 0.3
            }
            guard playing && moving else { continue }
            // Each bar at its own pace, starting from the middle of its range
            // so it picks up from where the spring left it.
            let speed = 3.0 + Double(i % 3) * 0.9 + Double(i) * 0.25
            let bounce = CABasicAnimation(keyPath: "bounds.size.height")
            bounce.fromValue = low
            bounce.toValue = high
            bounce.duration = Double.pi / speed / 2
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.timeOffset = bounce.duration / 2
            bounce.beginTime = now + settleTime
            layer.add(bounce, forKey: "bounce")
        }
    }
}

// MARK: - Compact activities

/// The shared layout of every compact activity: a glyph centered in the left
/// rounded end, a title, and a value centered toward the right end. On a notch
/// the camera takes the middle, so only the glyph and the value show.
struct CompactActivityRow<Leading: View, Trailing: View>: View {
    let title: String
    let notchWidth: CGFloat
    let height: CGFloat
    let layout: CompactLayout
    let showsTitle: Bool
    /// Shorter ways to say the title, tried in order when it doesn't fit
    /// ("MON 1 – 1 HOS" for "Montañesa 1 – 1 Hospitalet").
    var shorter: [String] = []
    /// A second line under the title, smaller, like the song's artist.
    var subtitle: String? = nil
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @ViewBuilder
    private var titleText: some View {
        if shorter.isEmpty {
            Text(title)
                .lineLimit(1)
        } else {
            // The longest that fits whole; the last one truncates if even it
            // doesn't.
            let all = [title] + shorter
            ViewThatFits(in: .horizontal) {
                ForEach(Array(all.enumerated()), id: \.offset) { index, text in
                    Text(text)
                        .lineLimit(1)
                        .fixedSize(horizontal: index < all.count - 1, vertical: false)
                }
            }
        }
    }

    var body: some View {
        if notchWidth > 0 && !showsTitle {
            // A real notch: each side gets its own wing and stays in it. The
            // middle is the camera housing (plus clearance) and is never
            // drawn on; a time too long for its wing shrinks instead of
            // sliding under the camera.
            HStack(spacing: 0) {
                leading
                    .frame(width: layout.artworkSize, height: layout.artworkSize)
                    .padding(.leading, layout.artworkInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear
                    .frame(width: notchWidth)
                trailing
                    .font(.system(size: layout.titleSize, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.trailing, layout.trailingInset + 4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .clipped()
            }
            .frame(height: height)
        } else {
            HStack(spacing: 8) {
                leading
                    .frame(width: layout.artworkSize, height: layout.artworkSize)
                if showsTitle, let subtitle, !subtitle.isEmpty {
                    // Title on top, the description under it, both sized to
                    // the pill's height like the song and artist.
                    let titleSize = min(14, max(10.5, (height * 0.37).rounded()))
                    VStack(alignment: .leading, spacing: -1) {
                        titleText
                            .font(.system(size: titleSize, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: (titleSize * 0.8).rounded()))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if showsTitle {
                    titleText
                        .font(.system(size: layout.titleSize, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                trailing
                    .font(.system(size: layout.titleSize, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.leading, layout.artworkInset)
            .padding(.trailing, layout.trailingInset + 4)
            .frame(height: height)
        }
    }
}

/// A thin progress ring with a symbol inside.
struct ProgressRing: View {
    /// nil spins (unknown progress).
    let progress: Double?
    let tint: Color
    var symbol: String? = nil

    var body: some View {
        GeometryReader { geo in
            let line = max(2, geo.size.width * 0.13)
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: line)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(progress, 1)))
                        .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    TimelineView(.animation) { context in
                        Circle()
                            .trim(from: 0, to: 0.3)
                            .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 360))
                    }
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: geo.size.width * 0.42, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
        }
    }
}

struct TimerActivityView: View {
    let timer: TimerController
    /// Which timer (several can run); nil = the one ending soonest.
    var itemID: UUID? = nil
    let notchWidth: CGFloat
    let height: CGFloat
    let layout: CompactLayout
    let showsTitle: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let item = timer.item(itemID)
            let kind = item?.kind ?? .timer
            let paused = item?.isPaused ?? false
            CompactActivityRow(title: paused ? "\(kind.title) Paused" : kind.title,
                               notchWidth: notchWidth, height: height, layout: layout,
                               showsTitle: showsTitle) {
                // The activity's symbol in the middle, like a download's arrow.
                if kind == .stopwatch {
                    ZStack {
                        StopwatchDial(elapsed: item?.elapsed(at: context.date) ?? 0, tint: kind.tint)
                        Image(systemName: kind.symbol)
                            .font(.system(size: (layout.artworkSize * 0.42).rounded(), weight: .bold))
                            .foregroundStyle(kind.tint)
                    }
                } else {
                    ProgressRing(progress: item?.progress(at: context.date) ?? 0, tint: kind.tint,
                                 symbol: kind.symbol)
                }
            } trailing: {
                Text(item?.display(at: context.date) ?? "0:00")
                    .foregroundStyle(kind.tint)
            }
        }
        .id(itemID)
        .transition(.opacity)
    }
}

struct EventActivityView: View {
    let event: CalendarMonitor.Event
    let minutes: Double
    let notchWidth: CGFloat
    let height: CGFloat
    let layout: CompactLayout
    let showsTitle: Bool

    var body: some View {
        CompactActivityRow(title: event.title, notchWidth: notchWidth, height: height,
                           layout: layout, showsTitle: showsTitle) {
            RoundedRectangle(cornerRadius: layout.artworkCorner, style: .continuous)
                .fill(event.color)
                .overlay(
                    Image(systemName: "calendar")
                        .font(.system(size: layout.artworkSize * 0.55, weight: .semibold))
                        .foregroundStyle(Color.white)
                )
        } trailing: {
            if minutes <= 0.5 {
                Text("Now").foregroundStyle(Color.green)
            } else {
                Text(showsTitle ? "in \(Int(minutes.rounded(.up))) min" : "\(Int(minutes.rounded(.up)))m")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "1h", "12m", then "9:59": fits the small circle.
func shortClock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3600 { return "\(seconds / 3600)h" }
    if seconds >= 600 { return "\(seconds / 60)m" }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// "4:05" or "1:02:03".
func callClock(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// A call in the pill: a green phone with the app and how long it's been
/// going ("FaceTime • 2:14"), and a waveform that moves with your voice.
struct CallActivityView: View {
    let call: CallMonitor.Call
    let isMuted: Bool
    let voice: CallVoiceMeter
    /// False in Brim Demo, where the call is made up and the mic stays off.
    var live = true
    let notchWidth: CGFloat
    let height: CGFloat
    let layout: CompactLayout
    let showsTitle: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let clock = callClock(context.date.timeIntervalSince(call.started))
            CompactActivityRow(title: "\(call.appName) \u{2022} \(clock)", notchWidth: notchWidth, height: height,
                               layout: layout, showsTitle: showsTitle, shorter: [clock]) {
                Circle()
                    .fill(Color.green)
                    .overlay(
                        Image(systemName: "phone.fill")
                            .font(.system(size: layout.artworkSize * 0.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                    )
            } trailing: {
                HStack(spacing: 5) {
                    if isMuted {
                        Image(systemName: "mic.slash.fill")
                            .foregroundStyle(Color.red)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        // Moves with your voice (the loudness only, never
                        // recorded). Muted, it gives way to the red mic.
                        CallVoiceWave(meter: voice, live: live)
                            .frame(width: layout.equalizerSize, height: layout.equalizerSize * 0.8)
                            .transition(.scale.combined(with: .opacity))
                    }
                    // No room for the app's name: the time stays here.
                    if !showsTitle {
                        Text(clock).foregroundStyle(Color.green)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isMuted)
            }
        }
        .onAppear { if live { voice.attach() } }
        .onDisappear { if live { voice.detach() } }
    }
}

/// In the panel: the call with Mute (the Mac's microphone) and a click to
/// bring the call's window forward.
struct CallRow: View {
    let call: CallMonitor.Call
    let isMuted: Bool
    let canMute: Bool
    let voice: CallVoiceMeter
    var live = true
    let onMute: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let url = AppLocator.url(for: call.bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                } else {
                    Image(systemName: "phone.circle.fill")
                        .resizable()
                        .foregroundStyle(Color.green)
                }
            }
            .frame(width: 22, height: 22)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 1) {
                    Text(call.appName)
                        .font(.system(size: fs(11.5), weight: .semibold))
                        .lineLimit(1)
                    Text("\(isMuted ? "Muted" : "Call") · \(callClock(context.date.timeIntervalSince(call.started)))")
                        .font(.system(size: fs(10)).monospacedDigit())
                        .foregroundStyle(isMuted ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.green))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isMuted {
                EqualizerView(color: .secondary, isPlaying: false)
                    .frame(width: 16, height: 16)
            } else {
                CallVoiceWave(meter: voice, live: live)
                    .frame(width: 18, height: 16)
            }
            Button(action: onMute) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: fs(12), weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(isMuted ? Color.white : Color.primary)
                    .frame(width: 28, height: 24)
                    .background(Capsule().fill(isMuted ? Color.red : Color.primary.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .disabled(!canMute)
            .opacity(canMute ? 1 : 0.4)
            .help(canMute ? (isMuted ? "Unmute the microphone" : "Mute the microphone")
                          : "This microphone can't be muted from Brim")
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onAppear { if live { voice.attach() } }
        .onDisappear { if live { voice.detach() } }
    }
}

/// "in 5 min", "Now", "10 min ago" for a reminder's due time.
private func reminderWhen(_ minutes: Double, short: Bool) -> String {
    if minutes > 0.5 { return short ? "\(Int(minutes.rounded(.up)))m" : "in \(Int(minutes.rounded(.up))) min" }
    if minutes > -1 { return "Now" }
    let late = Int((-minutes).rounded())
    if late >= 24 * 60 { return short ? "\(late / 1440)d" : "\(late / 1440) d ago" }
    if late >= 60 { return short ? "\(late / 60)h" : "\(late / 60) h ago" }
    return short ? "\(late)m" : "\(late) min ago"
}

/// A reminder due soon, in the pill: the Reminders icon, its title, and when.
struct ReminderActivityView: View {
    let reminder: ReminderMonitor.Item
    let minutes: Double
    let notchWidth: CGFloat
    let height: CGFloat
    let layout: CompactLayout
    let showsTitle: Bool

    var body: some View {
        CompactActivityRow(title: reminder.title, notchWidth: notchWidth, height: height,
                           layout: layout, showsTitle: showsTitle) {
            ReminderIcon()
        } trailing: {
            // Overdue in red, like the Reminders app.
            Text(reminderWhen(minutes, short: !showsTitle))
                .foregroundStyle(minutes > 0.5 ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                 : minutes < -1 ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        }
    }
}

/// The Reminders app's own icon (a checklist glyph if it can't be found).
struct ReminderIcon: View {
    var body: some View {
        if let icon = ReminderMonitor.appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "checklist")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color.orange)
        }
    }
}

/// In the panel: the reminder with a Done button that ticks it off.
struct ReminderRow: View {
    let reminder: ReminderMonitor.Item
    let minutes: Double
    let onDone: () -> Void
    /// Hides it in Brim (it stays open in Reminders).
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(reminder.color)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title)
                    .font(.system(size: fs(11.5), weight: .semibold))
                    .lineLimit(1)
                Text("\(reminder.due.formatted(date: .omitted, time: .shortened)) · \(reminderWhen(minutes, short: false))")
                    .font(.system(size: fs(10)))
                    .foregroundStyle(minutes < -1 ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: fs(11), weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(reminder.color))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            SmallIconButton(symbol: "xmark", action: onDismiss)
                .accessibilityLabel("Hide this reminder")
                .help("Hide in Brim (it stays in Reminders)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct DownloadActivityView: View {
    let download: DownloadMonitor.Active
    let notchWidth: CGFloat
    let height: CGFloat
    let layout: CompactLayout
    let showsTitle: Bool

    var body: some View {
        CompactActivityRow(title: download.title,
                           notchWidth: notchWidth, height: height, layout: layout, showsTitle: showsTitle) {
            ProgressRing(progress: download.fraction, tint: .blue, symbol: download.symbol)
        } trailing: {
            if let fraction = download.fraction {
                Text("\(Int(fraction * 100))%").foregroundStyle(.secondary)
            }
        }
    }
}

/// The idle island shows the time, quietly, with the weather beside it and a
/// small cup while Keep Awake is on.
struct IdleClockView: View {
    let height: CGFloat
    let fontSize: CGFloat
    var showsClock = true
    var weather: WeatherMonitor.Now? = nil
    var keepsAwake = false
    /// Beside a real notch: the camera housing (plus clearance) in the
    /// middle, never drawn on. 0 for the island.
    var cameraGap: CGFloat = 0

    /// Keep Awake's cup. It pops in from small, slightly blurred.
    private func cup(size: CGFloat) -> some View {
        Image(systemName: "cup.and.saucer.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.orange)
            .transition(.asymmetric(
                insertion: .modifier(active: BlurOpacity(radius: 4, opacity: 0),
                                     identity: BlurOpacity(radius: 0, opacity: 1))
                    .combined(with: .scale(scale: 0.3)),
                removal: .opacity.combined(with: .scale(scale: 0.5))))
    }

    /// The temperature, then the sky in color, like the Weather app. With
    /// Keep Awake on, the pill's ends are shared with the cup, so the sky sits
    /// on top of a smaller temperature instead: narrower, and level with the
    /// cup across the clock.
    @ViewBuilder
    private func weatherView(_ weather: WeatherMonitor.Now, stacked: Bool) -> some View {
        let symbol = Image(systemName: weather.symbol)
            .symbolRenderingMode(.multicolor)
            .foregroundStyle(.primary)
        if stacked {
            VStack(spacing: 0) {
                symbol.font(.system(size: (fontSize * 0.68).rounded(), weight: .semibold))
                Text("\(weather.temperature)°")
                    .font(.system(size: (fontSize * 0.62).rounded(), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
        } else {
            HStack(spacing: 3) {
                Text("\(weather.temperature)°")
                    .font(.system(size: (fontSize * 0.78).rounded(), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                symbol.font(.system(size: (fontSize * 0.74).rounded(), weight: .semibold))
            }
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
        }
    }

    var body: some View {
        if cameraGap > 0 {
            besideNotch
        } else {
            inIsland
        }
    }

    /// Beside a notch: the time in the left wing; the cup and the weather in
    /// the right one (the sky on top of the temperature while the cup is
    /// there, so they fit). The time has no AM/PM, to fit its wing.
    private var besideNotch: some View {
        TimelineView(.everyMinute) { context in
            let inset = (height * 0.36).rounded()
            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    if showsClock {
                        Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                            .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .padding(.leading, inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear
                    .frame(width: cameraGap)
                HStack(spacing: (fontSize * 0.4).rounded()) {
                    if keepsAwake { cup(size: (fontSize * 0.8).rounded()) }
                    if let weather { weatherView(weather, stacked: keepsAwake) }
                }
                .padding(.trailing, inset)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: keepsAwake)
            .animation(.easeInOut(duration: 0.3), value: weather)
        }
        .frame(height: height)
    }

    private var inIsland: some View {
        TimelineView(.everyMinute) { context in
            // The clock is the biggest. With Keep Awake on it moves to the
            // exact middle, the cup on its left and the weather on its right;
            // otherwise it sits on the left with the weather on the right.
            // Everything keeps the same distance from the pill's ends.
            let inset = (height * 0.48).rounded()
            let gap = (fontSize * 0.5).rounded()
            let cupSize = (fontSize * 0.8).rounded()
            let centered = keepsAwake || weather == nil
            Group {
                if showsClock {
                    HStack(spacing: 0) {
                        // Left column: the cup. Collapses to nothing when Keep
                        // Awake is off, so the clock slides back to the left.
                        ZStack(alignment: .leading) {
                            if keepsAwake {
                                cup(size: cupSize)
                                    .padding(.trailing, gap)
                            }
                        }
                        .frame(maxWidth: centered ? .infinity : 0, alignment: .leading)
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        // Right column, the same width as the left one, so the
                        // clock stays exactly centered.
                        ZStack(alignment: .trailing) {
                            if let weather {
                                weatherView(weather, stacked: keepsAwake)
                                    .padding(.leading, gap)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, inset)
                } else {
                    HStack(spacing: gap) {
                        if keepsAwake { cup(size: cupSize) }
                        if let weather { weatherView(weather, stacked: false) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A touch of bounce as the cup pops in and the clock makes room.
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: keepsAwake)
            .animation(.easeInOut(duration: 0.3), value: weather)
        }
        .frame(height: height)
    }
}

/// Green when the camera is on, orange when the microphone is, like iPhone.
struct PrivacyDots: View {
    static let defaultSize: CGFloat = 6
    let camera: Bool
    let microphone: Bool
    var size: CGFloat = PrivacyDots.defaultSize

    var body: some View {
        HStack(spacing: 4) {
            if camera { dot(.green) }
            if microphone { dot(.orange) }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 3)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}

// MARK: - Lock screen

/// Locked: a lock in the left wing (music keeps its equalizer on the right).
/// Unlocking: the shackle swings open with Magic Replace, then the notch settles.
struct LockActivityView: View {
    let isOpen: Bool
    let height: CGFloat
    /// Same spots as the artwork in the music pill (used beside a notch).
    let layout: CompactLayout
    /// Island: the lock alone, centered. Notch: the lock in the left wing.
    let centered: Bool

    var body: some View {
        let glyph = LockGlyph(isOpen: isOpen, size: (layout.artworkSize * 0.72).rounded())
            .frame(width: layout.artworkSize, height: layout.artworkSize)
        Group {
            if centered {
                glyph.frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 0) {
                    glyph
                    Spacer(minLength: 0)
                }
                .padding(.leading, layout.artworkInset)
            }
        }
        .frame(height: height)
    }
}

/// SF Symbols `lock.fill` and `lock.open.fill`: the same pair the iPhone uses.
struct LockGlyph: View {
    let isOpen: Bool
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: isOpen ? "lock.open.fill" : "lock.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.primary)
            .modifier(MagicReplace())
    }
}

/// Magic Replace (macOS 15+) animates only the parts of a symbol that change:
/// the shackle opens while the body stays put. Earlier versions crossfade.
private struct MagicReplace: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
        } else {
            content.contentTransition(.symbolEffect(.replace))
        }
    }
}

// MARK: - Banner

/// Laid out like a macOS notification: app icon, bold title with the time on the
/// right, then subtitle and body.
struct BannerView: View {
    let alert: NotchAlert
    let topInset: CGFloat
    /// Locked screen: show which app it's from, but not what it says.
    var hidesPreview = false

    private var isPrivate: Bool { hidesPreview && alert.appName != nil }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            HStack(alignment: .center, spacing: 12) {
                AlertIcon(alert: alert, size: 38, animatesProducts: true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(isPrivate ? alert.appName ?? alert.title : alert.title)
                            .font(.system(size: fs(13), weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if alert.battery == nil && alert.levelFraction == nil {
                            Text(alert.date.notchTimestamp)
                                .font(.system(size: fs(11)))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if isPrivate {
                        Text("Notification")
                            .font(.system(size: fs(12)))
                            .foregroundStyle(.secondary)
                    }
                    if !isPrivate, let subtitle = alert.subtitle {
                        Text(subtitle)
                            .font(.system(size: fs(12), weight: .medium))
                            .lineLimit(1)
                            // Changes in place fade: Muted to AirPods, Level 3 to Off, On to Muted.
                            .contentTransition(.opacity)
                    }
                    if !isPrivate, let message = alert.body {
                        Text(message)
                            .font(.system(size: fs(12)))
                            .foregroundStyle(.secondary)
                            .lineLimit(alert.subtitle == nil ? 2 : 1)
                    }
                }
                if let battery = alert.battery {
                    BatteryRingsView(battery: battery, deviceSymbol: alert.symbol)
                }
                if let fraction = alert.levelFraction {
                    LevelBarView(fraction: fraction)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 17)
            .frame(maxHeight: .infinity)
        }
    }
}

struct AlertIcon: View {
    let alert: NotchAlert
    let size: CGFloat

    /// Earbuds when they connect; the open case when it's opened next to
    /// the Mac with them inside; the case on its own when only its battery
    /// is reported (earbuds out, or the case charging by itself).
    static func clipVariant(for alert: NotchAlert) -> DeviceAnimations.Variant {
        let battery = alert.battery
        let budsReported = battery?.left != nil || battery?.right != nil
        if battery?.caseLevel != nil, !budsReported { return .closedCase }
        return alert.subtitle == "Nearby" ? .openCase : .buds
    }
    /// The banner itself: Apple devices turn like a 3D model (not in lists).
    var animatesProducts = false

    var body: some View {
        if alert.fromiPhone {
            // An iPhone app: its square icon with iOS's corners (or its
            // initial on a colour when the Mac has no copy of the icon), and
            // a small iPhone mark, like macOS shows.
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon = alert.appIcon, alert.iconHasShape {
                        // Shaped already, with its own margin and shadow.
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else if let icon = alert.appIcon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
                    } else {
                        let tint = ExternalAppIcon.tint(for: alert.bundleID ?? alert.title)
                        LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                            .overlay(
                                Text(String((alert.appName ?? alert.title).prefix(1)).uppercased())
                                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white)
                            )
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: alert.iconHasShape ? 0 : size * 0.2237, style: .continuous))
                Image(systemName: "iphone")
                    .font(.system(size: size * 0.26, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(size * 0.07)
                    .background(Circle().fill(Color.black.opacity(0.75)))
                    .offset(x: size * 0.14, y: size * 0.14)
            }
            .frame(width: size, height: size)
        } else if let icon = alert.appIcon {
            // App icons already carry their own shape and shadow.
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else if let image = alert.image {
            ArtworkView(image: image, size: size, corner: size * 0.25)
        } else if let volume = alert.volume {
            // Volume: the speaker stays put, the waves add up.
            ZStack {
                Circle().fill(alert.tint.opacity(0.18))
                VolumeSymbol(reading: volume)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(alert.tint)
            }
            .frame(width: size, height: size)
        } else if let backlight = alert.backlight {
            // Keyboard backlight: the rays grow with the level.
            ZStack {
                Circle().fill(alert.tint.opacity(0.18))
                BacklightGlyph(reading: backlight, size: size * 0.62)
                    .foregroundStyle(alert.tint)
            }
            .frame(width: size, height: size)
        } else if animatesProducts,
                  alert.battery != nil || ["Connected", "Disconnected", "Nearby"].contains(alert.subtitle ?? ""),
                  let clip = DeviceAnimations.clip(forDevice: alert.title, variant: Self.clipVariant(for: alert)) {
            // AirPods and Beats turn on a turntable, like on iPhone.
            Group {
                if clip.isSheet {
                    DeviceSheetView(url: clip.url)
                } else {
                    DeviceAnimationView(clip: clip)
                }
            }
            .frame(width: size * 1.1, height: size * 1.1)
            .frame(width: size, height: size)
            .id(alert.id)
        } else {
            ZStack {
                Circle().fill(alert.tint.opacity(0.18))
                Image(systemName: alert.symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(alert.tint)
                    // Only the parts that change move: the volume's waves, the
                    // microphone's slash.
                    .modifier(MagicReplace())
            }
            .frame(width: size, height: size)
        }
    }
}

/// The level bar in the backlight and volume banners, like the macOS
/// brightness HUD: a capsule that fills up to the level.
struct LevelBarView: View {
    /// 0...1
    let fraction: Double

    static let width: CGFloat = 96
    static let height: CGFloat = 6

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.18))
            Capsule()
                .fill(Color.white)
                .frame(width: Self.width * CGFloat(min(max(fraction, 0), 1)))
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(Capsule())
        .animation(.spring(response: 0.18, dampingFraction: 0.92), value: fraction)
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

// MARK: - Battery

/// One ring per AirPod and one for the case, like the iPhone's AirPods card.
struct BatteryRingsView: View {
    let battery: DeviceBattery
    /// The device's SF Symbol, used for single-battery devices.
    let deviceSymbol: String

    private var caseSymbol: String {
        deviceSymbol.contains("pro") ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let left = battery.left {
                BatteryRing(level: left, charging: battery.leftCharging, symbol: "airpod.left")
            }
            if let right = battery.right {
                BatteryRing(level: right, charging: battery.rightCharging, symbol: "airpod.right")
            }
            if let caseLevel = battery.caseLevel {
                BatteryRing(level: caseLevel, charging: battery.caseCharging, symbol: caseSymbol)
            }
            if let single = battery.single {
                BatteryRing(level: single, charging: battery.singleCharging, symbol: deviceSymbol)
            }
        }
    }
}

struct BatteryRing: View {
    let level: Int
    let charging: Bool
    let symbol: String

    /// Green, red at 20% and below, the same colors iOS uses.
    private var color: Color { level <= 20 ? .red : .green }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(level) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: charging ? "bolt.fill" : symbol)
                    .font(.system(size: fs(11), weight: .medium))
                    .foregroundStyle(charging ? color : Color.primary)
            }
            .frame(width: 28, height: 28)
            Text("\(level)%")
                .font(.system(size: fs(9.5), weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Expanded (hover)

struct ExpandedView: View {
    let vm: NotchViewModel
    let media: MediaController
    let alerts: AlertCenter
    /// Shared with the flying artwork, so it lands exactly in its spot.
    let layout: PanelLayout

    @Environment(NotchUIState.self) private var ui

    var body: some View {
        panel
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: layout.headerHeight)
                .padding(.top, layout.headerTop)

            HStack(alignment: .top, spacing: fs(16)) {
                Group {
                    if ui.showsMirror {
                        MirrorView { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { ui.showsMirror = false } }
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else if ui.showsScripts {
                        PrompterLibraryView(vm: vm)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        VStack(alignment: .leading, spacing: fs(12)) {
                            PlayerView(media: media)
                                .fixedSize(horizontal: false, vertical: true)
                            // A tall panel: the shelf takes the space under
                            // the player instead of the notifications' side.
                            if shelfUnderPlayer {
                                ShelfView(vm: vm, isTargeted: ui.shelfDropTargeted, fillsHeight: true)
                                    .transition(.opacity)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
                    .padding(.bottom, 2)
                activityColumn
                    .frame(width: vm.activityColumnWidth)
            }
            .padding(.top, layout.contentTop - layout.headerTop - layout.headerHeight)
            .padding(.bottom, layout.margin)
        }
        .padding(.horizontal, layout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A file dropped anywhere on the panel goes on the shelf (the
        // teleprompter section, when it's open, takes its own drops).
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { ui.shelfDropTargeted },
                                                     set: { ui.shelfDropTargeted = $0 })) { providers in
            vm.shelf.importDrop(providers)
        }
        .onAppear { vm.shelf.prune() }
    }

    /// What's playing on the left (with the app's real icon, browsers too);
    /// the panel's buttons, the notification count and Clear on the right.
    /// On a real notch the camera sits in the middle of the top row, so the
    /// top row keeps only what's playing and the count, one on each side of
    /// the camera, and the buttons get a row of their own below it.
    @ViewBuilder
    private var header: some View {
        if vm.cameraGap > 0 {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        nowPlayingLabel
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    Color.clear
                        .frame(width: vm.cameraGap)
                    HStack(spacing: 6) {
                        // Just right of the camera, where they are when the
                        // panel is closed.
                        privacyDots
                            .padding(.leading, 2)
                        Spacer(minLength: 8)
                        notificationsControls
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: vm.closedSize.height)
                HStack(spacing: 6) {
                    // A menu sliding out of a button needs the row: the
                    // Shortcuts step aside until it folds away.
                    if ui.openMenu == nil { shortcutButtons }
                    Spacer(minLength: 12)
                        .layoutPriority(-1)
                    toolButtons
                }
                .frame(height: NotchViewModel.toolRowHeight)
            }
            .font(.system(size: fs(11), weight: .medium))
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                nowPlayingLabel
                // While a menu slides out of a button (the timer's presets,
                // brightness), the Shortcuts and the notification count and
                // Clear step aside, so the row never runs past the panel.
                if ui.openMenu == nil { shortcutButtons }
                Spacer(minLength: 12)
                    .layoutPriority(-1)
                // The island keeps its own dots at the top center, open or
                // closed, so only a drawn notch puts them in this row.
                if !vm.isIsland {
                    privacyDots
                        .padding(.trailing, 4)
                }
                toolButtons
                if ui.openMenu == nil { notificationsControls }
            }
            .font(.system(size: fs(11), weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    /// The camera and microphone dots, as an item in the header row (no
    /// width when neither is on).
    private var privacyDots: some View {
        PrivacyDots(camera: vm.showPrivacyDots && vm.cameraDotOn,
                    microphone: vm.showPrivacyDots && vm.micDotOn)
            .animation(.easeOut(duration: 0.2), value: vm.cameraDotOn)
            .animation(.easeOut(duration: 0.2), value: vm.micDotOn)
    }

    @ViewBuilder
    private var nowPlayingLabel: some View {
            if let id = media.sourceBundleID, let url = AppLocator.url(for: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                    .lineLimit(1)
            } else {
                Text("Now Playing")
                    .lineLimit(1)
            }
    }

    @ViewBuilder
    private var shortcutButtons: some View {
            // Your Shortcuts buttons (Settings > General).
            if !vm.shortcuts.buttons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(vm.shortcuts.buttons) { shortcut in
                        ShortcutHeaderButton(shortcut: shortcut,
                                             isRunning: vm.shortcuts.running.contains(shortcut.name)) {
                            vm.shortcuts.run(shortcut)
                        }
                    }
                }
                .padding(.leading, 6)
                .fixedSize()
            }
    }

    @ViewBuilder
    private var toolButtons: some View {
            // Each button's options slide out of it to the left; the button
            // itself stays put. One menu at a time.
            // Mirror: your camera, to check how you look before a call.
            HeaderMenuButton(symbol: "person.crop.square", tint: nil, isOpen: ui.showsMirror,
                             label: ui.showsMirror ? "Close Mirror" : "Mirror") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    ui.openMenu = nil
                    ui.showsScripts = false
                    ui.showsMirror.toggle()
                }
            }
            // Teleprompter: drop or browse for a script, or pick a recent one.
            HeaderMenuButton(symbol: "text.alignleft", tint: nil, isOpen: ui.showsScripts,
                             label: ui.showsScripts ? "Close Teleprompter" : "Teleprompter") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    ui.openMenu = nil
                    ui.showsMirror = false
                    ui.showsScripts.toggle()
                }
            }
            // Monitor brightness (only when the monitor answers DDC).
            if vm.showBrightness && vm.brightness.isAvailable {
                if ui.openMenu == .brightness {
                    HeaderMenuStrip {
                        HStack(spacing: 6) {
                            Image(systemName: "sun.min.fill")
                                .font(.system(size: fs(10), weight: .semibold))
                            Slider(value: Binding(get: { vm.brightness.level },
                                                  set: { vm.brightness.setLevel($0) }),
                                   in: 0...1)
                                .controlSize(.small)
                                .frame(width: 110)
                            Image(systemName: "sun.max.fill")
                                .font(.system(size: fs(11), weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                    }
                    .transition(.headerMenu)
                }
                HeaderMenuButton(symbol: "sun.max.fill", tint: nil,
                                 isOpen: ui.openMenu == .brightness,
                                 label: "Brightness") {
                    if ui.openMenu != .brightness { vm.brightness.refresh() }
                    toggleMenu(.brightness)
                }
            }
            if ui.openMenu == .keepAwake {
                HeaderMenuStrip {
                    PresetChip("1 hr") { choose { vm.keepAwake.start(for: 3600) } }
                    PresetChip("4 hr") { choose { vm.keepAwake.start(for: 4 * 3600) } }
                    PresetChip("Until Off") { choose { vm.keepAwake.start(for: nil) } }
                    if vm.keepAwake.isOn {
                        PresetChip("Off") { choose { vm.keepAwake.stop() } }
                    }
                }
                .transition(.headerMenu)
            }
            HeaderMenuButton(symbol: vm.keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer",
                             tint: vm.keepAwake.isOn ? .orange : nil,
                             isOpen: ui.openMenu == .keepAwake,
                             label: vm.keepAwake.isOn ? "Keep Awake is on" : "Keep Awake") {
                toggleMenu(.keepAwake)
            }
            if ui.openMenu == .timer {
                HeaderMenuStrip {
                    PresetChip("5m") { choose { vm.timer.startTimer(minutes: 5) } }
                    PresetChip("10m") { choose { vm.timer.startTimer(minutes: 10) } }
                    PresetChip("15m") { choose { vm.timer.startTimer(minutes: 15) } }
                    PresetChip("Focus") { choose { vm.timer.startFocus() } }
                    IconChip(symbol: "stopwatch", label: "Stopwatch") { choose { vm.timer.startStopwatch() } }
                    PresetChip("Custom", tint: .orange) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { ui.openMenu = .customTimer }
                    }
                }
                .transition(.headerMenu)
            }
            if ui.openMenu == .customTimer {
                CustomTimerField(
                    cancel: { toggleMenu(.customTimer) },
                    start: { seconds in
                        UserDefaults.standard.set(seconds, forKey: "lastCustomTimer")
                        choose { vm.timer.startTimer(seconds: TimeInterval(seconds)) }
                    })
                    .transition(.headerMenu)
            }
            HeaderMenuButton(symbol: "timer", tint: nil,
                             isOpen: ui.openMenu == .timer || ui.openMenu == .customTimer,
                             label: "Add a timer") {
                if ui.openMenu == .customTimer { toggleMenu(.customTimer) } else { toggleMenu(.timer) }
            }
            .padding(.trailing, 4)
    }

    @ViewBuilder
    private var notificationsControls: some View {
            if !alerts.history.isEmpty {
                // The count steps aside while a menu is out, so the menu,
                // the buttons and Clear always fit.
                if ui.openMenu == nil {
                    Text("\(alerts.history.count) Notifications")
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
                Button("Clear") { alerts.clearAllAnimated() }
                    .buttonStyle(PressStyle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .padding(.leading, 4)
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
    }

    private func toggleMenu(_ menu: HeaderMenu) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            ui.openMenu = ui.openMenu == menu ? nil : menu
        }
    }

    /// Runs a menu choice; the new timer drops in above the notifications
    /// as the menu slides back into its button.
    private func choose(_ action: () -> Void) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            action()
            ui.openMenu = nil
        }
    }

    /// Time-sensitive things first (timer, next meeting, download), then
    /// notifications filling the rest.
    /// Tall enough for the shelf under the player, in the space the player
    /// leaves empty: the player's height plus room for a row of files.
    private var shelfUnderPlayer: Bool {
        guard !ui.showsMirror, !ui.showsScripts else { return false }
        let contentArea = vm.panelSize.height - PanelLayout.island.contentTop - PanelLayout.island.margin
        return contentArea - PanelLayout.artworkSize - fs(12) >= fs(92)
    }

    private var activityColumn: some View {
        VStack(spacing: 6) {
            // Files dropped on the island (under the player instead, when
            // the panel is tall enough).
            if !shelfUnderPlayer, !vm.shelf.items.isEmpty || ui.shelfDropTargeted {
                ShelfView(vm: vm, isTargeted: ui.shelfDropTargeted)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
            // Every running timer, newest on top.
            ForEach(vm.timer.items) { item in
                TimerRow(item: item, timer: vm.timer)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.9))))
            }
            if let event = vm.upcomingEvent {
                EventCard(event: event, minutes: vm.calendar.minutesUntil(event))
            }
            if let call = vm.currentCall {
                CallRow(call: call, isMuted: vm.callIsMuted, canMute: vm.callCanMute,
                        voice: vm.callVoice, live: !vm.demo.isRunning,
                        onMute: { vm.toggleCallMute() }, onOpen: { if !vm.demo.isRunning { vm.calls.openApp() } })
            }
            if let reminder = vm.upcomingReminder {
                ReminderRow(reminder: reminder, minutes: vm.reminders.minutesUntil(reminder),
                            onDone: { vm.reminders.complete(reminder) },
                            onDismiss: { withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { vm.reminders.dismiss(reminder) } })
            }
            if let download = vm.currentDownload {
                DownloadRow(download: download)
            }
            NotificationListView(alerts: alerts, liveActivities: vm.liveActivities)
        }
    }
}

/// One running timer: its kind, the time, pause and stop.
struct TimerRow: View {
    let item: TimerController.Item
    let timer: TimerController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: fs(11), weight: .semibold))
                .foregroundStyle(item.kind.tint)
            Text(item.isPaused ? "\(item.kind.title) Paused" : item.kind.title)
                .font(.system(size: fs(11.5), weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(item.display(at: context.date))
                    .font(.system(size: fs(12), weight: .semibold).monospacedDigit())
                    .foregroundStyle(item.kind.tint.opacity(item.isPaused ? 0.55 : 1))
            }
            SmallIconButton(symbol: item.isPaused ? "play.fill" : "pause.fill") { timer.togglePause(item.id) }
                .accessibilityLabel(item.isPaused ? "Resume" : "Pause")
            SmallIconButton(symbol: "xmark") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { timer.stop(item.id) }
            }
            .accessibilityLabel("Stop")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// A header button that opens a menu; lit while its menu is open.
struct HeaderMenuButton: View {
    let symbol: String
    let tint: Color?
    let isOpen: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fs(12), weight: .semibold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(HierarchicalShapeStyle.primary))
                .frame(width: 26, height: 26)
                .background(Circle().fill(isOpen ? Color.primary.opacity(0.22)
                                                 : (tint?.opacity(0.2) ?? Color.primary.opacity(0.1))))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressedScale: 0.88))
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The options that slide out of a header button.
struct HeaderMenuStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}

extension AnyTransition {
    /// Grows out of the button on its right, and folds back into it.
    static var headerMenu: AnyTransition {
        .scale(scale: 0.15, anchor: .trailing)
            .combined(with: .opacity)
            .combined(with: .offset(x: 12))
    }
}

/// The next meeting, with a Join button when the invite has a video link.
struct EventCard: View {
    let event: CalendarMonitor.Event
    let minutes: Double

    private var when: String {
        let time = event.start.formatted(date: .omitted, time: .shortened)
        if minutes <= 0.5 { return "\(time) · Now" }
        if minutes < 60 { return "\(time) · in \(Int(minutes.rounded(.up))) min" }
        return time
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(event.color)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: fs(11.5), weight: .semibold))
                    .lineLimit(1)
                Text(when)
                    .font(.system(size: fs(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let link = event.joinURL {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Text("Join")
                        .font(.system(size: fs(11), weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct DownloadRow: View {
    let download: DownloadMonitor.Active

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: download.isAirDrop ? DownloadMonitor.Active.airDropSymbol : "arrow.down.circle.fill")
                .font(.system(size: fs(15)))
                .foregroundStyle(Color.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(download.title)
                        .font(.system(size: fs(11.5), weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let fraction = download.fraction {
                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: fs(10), weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let fraction = download.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.blue)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.blue)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct SmallIconButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fs(9.5), weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressedScale: 0.88))
    }
}

struct PresetChip: View {
    let title: String
    var tint: Color? = nil
    let action: () -> Void

    init(_ title: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fs(11.5), weight: .semibold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(HierarchicalShapeStyle.primary))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(tint?.opacity(0.2) ?? Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// The custom timer, set right in the header: "0 : 25 : 00". Point at a
/// number and scroll (mouse wheel, trackpad, or a Logitech wheel or
/// thumbwheel) to change it; the tick starts the timer, the x folds it away.
struct CustomTimerField: View {
    let cancel: () -> Void
    let start: (Int) -> Void
    @Environment(NotchUIState.self) private var ui

    private static let limits = [24, 60, 60]  // hours wrap at 24, minutes and seconds at 60

    private var totalSeconds: Int {
        ui.customTime[0] * 3600 + ui.customTime[1] * 60 + ui.customTime[2]
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                part(0)
                colon
                part(1)
                colon
                part(2)
            }
            .font(.system(size: fs(13), weight: .semibold).monospacedDigit())
            .padding(.horizontal, 4)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: fs(9.5), weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Cancel")
            Button { start(totalSeconds) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: fs(10.5), weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.orange))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .disabled(totalSeconds == 0)
            .opacity(totalSeconds == 0 ? 0.4 : 1)
            .accessibilityLabel("Start timer")
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
        .onDisappear { ui.customHover = nil }
    }

    private var colon: some View {
        Text(":").foregroundStyle(.tertiary)
    }

    private func part(_ index: Int) -> some View {
        let value = ui.customTime[index]
        let hovering = ui.customHover == index
        return Text(index == 0 ? "\(value)" : String(format: "%02d", value))
            .contentTransition(.numericText(value: Double(value)))
            .foregroundStyle(hovering ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .padding(.horizontal, 4)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color.orange.opacity(0.2) : Color.clear))
            // Tiny arrows say "scroll me" while it's under the pointer.
            .overlay(alignment: .top) {
                if hovering {
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: fs(7), weight: .bold))
                        .foregroundStyle(Color.orange.opacity(0.7))
                        .offset(y: -6)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if hovering {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: fs(7), weight: .bold))
                        .foregroundStyle(Color.orange.opacity(0.7))
                        .offset(y: 6)
                        .transition(.opacity)
                }
            }
            .overlay {
                ScrollCatcher { step in
                    let limit = Self.limits[index]
                    withAnimation(.snappy(duration: 0.18)) {
                        ui.customTime[index] = (ui.customTime[index] + step + limit) % limit
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
            }
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) {
                    if inside { ui.customHover = index } else if ui.customHover == index { ui.customHover = nil }
                }
            }
            .accessibilityLabel(["Hours", "Minutes", "Seconds"][index])
            .accessibilityValue("\(value)")
            .accessibilityAdjustableAction { direction in
                let limit = Self.limits[index]
                let step = direction == .increment ? 1 : -1
                ui.customTime[index] = (ui.customTime[index] + step + limit) % limit
            }
    }
}

/// Turns scrolling over a view into steps: +1 for each notch up, -1 down.
/// A mouse wheel moves one step per click; a trackpad or a free-spinning
/// wheel moves one step per bit of distance. Sideways wheels (a Logitech
/// thumbwheel) count too. Follows the "natural scrolling" setting.
struct ScrollCatcher: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onStep = onStep
    }

    final class CatcherView: NSView {
        var onStep: ((Int) -> Void)?
        private var pending: CGFloat = 0
        private static let distancePerStep: CGFloat = 14

        override func scrollWheel(with event: NSEvent) {
            let dy = event.scrollingDeltaY, dx = event.scrollingDeltaX
            var delta = abs(dy) >= abs(dx) ? dy : -dx
            if event.isDirectionInvertedFromDevice { delta = -delta }
            if event.hasPreciseScrollingDeltas {
                if event.phase.contains(.began) { pending = 0 }
                pending += delta
                while abs(pending) >= Self.distancePerStep {
                    let step = pending > 0 ? 1 : -1
                    onStep?(step)
                    pending -= CGFloat(step) * Self.distancePerStep
                }
            } else if delta != 0 {
                onStep?(delta > 0 ? 1 : -1)
            }
        }
    }
}

/// A menu option shown as a symbol, the same height as the text options.
struct IconChip: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fs(11.5), weight: .semibold))
                .foregroundStyle(.primary)  // full strength, like the text options
                .frame(width: 30, height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

struct PlayerView: View {
    let media: MediaController
    /// Clicking the song opens its app (not on the lock screen).
    var opensApp = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        if let track = media.track {
            HStack(alignment: .top, spacing: fs(14)) {
                // The island draws the artwork here (it flies in from the pill).
                Color.clear.frame(width: PanelLayout.artworkSize, height: PanelLayout.artworkSize)

                VStack(alignment: .leading, spacing: fs(7)) {
                    // Click the song to open the app that's playing it.
                    ZStack(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.system(size: fs(13), weight: .semibold))
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.system(size: fs(11.5)))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(media.trackKey)
                        .transition(songSwipe(forward: media.trackDirection > 0, layout: layoutDirection, reduceMotion: reduceMotion))
                    }
                    .clipped()
                    .padding(.trailing, media.canLove ? 26 : 0)  // room for the star
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.88),
                               value: media.trackKey)
                    .contentShape(Rectangle())
                    .onTapGesture { if opensApp { media.openSourceApp() } }
                    .overlay(alignment: .topTrailing) {
                        // Apple Music's favourite, like the star in its own player.
                        if media.canLove {
                            Button { media.toggleLoved() } label: {
                                Image(systemName: media.isLoved == true ? "star.fill" : "star")
                                    .font(.system(size: fs(12), weight: .semibold))
                                    .foregroundStyle(media.isLoved == true ? AnyShapeStyle(Color.pink)
                                                                           : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                                    .contentTransition(.symbolEffect(.replace))
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                            .accessibilityLabel(media.isLoved == true ? "Remove from favourites" : "Favourite")
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: media.isLoved)
                        }
                    }
                    ProgressBar(media: media)
                    HStack(spacing: fs(6)) {
                        ModeButton(id: "shuffle", symbol: "shuffle", isOn: media.shuffleOn == true,
                                   label: media.shuffleOn == true ? "Shuffle on" : "Shuffle off") { media.toggleShuffle() }
                        ControlButton(id: "previous", symbol: "backward.fill", size: 14) { media.previous() }
                        ControlButton(id: "playPause", symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 20) { media.playPause() }
                        ControlButton(id: "next", symbol: "forward.fill", size: 14) { media.next() }
                        ModeButton(id: "repeat", symbol: media.repeatMode == .one ? "repeat.1" : "repeat",
                                   isOn: (media.repeatMode ?? .off) != .off,
                                   label: media.repeatMode == .one ? "Repeat one" : (media.repeatMode == .all ? "Repeat all" : "Repeat off")) {
                            media.cycleRepeat()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            EmptyPlayerView(media: media)
        }
    }
}

/// Shuffle and repeat: small, and tinted when on, like Apple Music.
struct ModeButton: View {
    let id: String
    let symbol: String
    let isOn: Bool
    let label: String
    let action: () -> Void
    @Environment(NotchUIState.self) private var ui

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fs(11), weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: fs(26), height: fs(24))
                .background(Circle().fill(Color.primary.opacity(ui.hoveredControl == id ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(pressedScale: 0.88))
        .accessibilityLabel(label)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .onHover { inside in
            if inside { ui.hoveredControl = id } else if ui.hoveredControl == id { ui.hoveredControl = nil }
        }
    }
}

#if DEMO
/// Brim Demo's mirror: a purple-blue gradient with a white silhouette, in
/// place of the camera.
struct DemoMirror: View {
    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                LinearGradient(colors: [Color(red: 0.56, green: 0.49, blue: 0.94),
                                        Color(red: 0.36, green: 0.48, blue: 0.91),
                                        Color(red: 0.17, green: 0.24, blue: 0.56)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.3, y: 0.2),
                               startRadius: 0, endRadius: side * 0.6)
                Ellipse()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: side * 0.29, height: side * 0.33)
                    .position(x: side / 2, y: side * 0.41)
                UnevenRoundedRectangle(topLeadingRadius: side * 0.34, topTrailingRadius: side * 0.34)
                    .fill(Color.white.opacity(0.45))
                    .frame(width: side * 0.69, height: side * 0.36)
                    .position(x: side / 2, y: side * 0.82 + side * 0.03)
            }
            .frame(width: side, height: side)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
#endif

/// The Mac's camera as a square mirror, in the player's place (the panel
/// grows to make room). The camera runs only while this is on screen (the
/// green dot shows), and stops when you close it or the panel.
struct MirrorView: View {
    let close: () -> Void
    private let camera = MirrorCamera.shared

    var body: some View {
        #if DEMO
        // Brim Demo: never the camera. A soft gradient and a silhouette.
        DemoMirror()
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                overlayButton("xmark", label: "Close Mirror", action: close)
                    .padding(7)
            }
        #else
        cameraMirror
        #endif
    }

    private var cameraMirror: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            switch camera.access {
            case .denied:
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.system(size: fs(18)))
                        .foregroundStyle(.secondary)
                    Text("Brim can't use the camera")
                        .font(.system(size: fs(11), weight: .semibold))
                    Button("Open Camera Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(PressStyle())
                    .font(.system(size: fs(10.5), weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
            case .noCamera:
                Text("No camera found")
                    .font(.system(size: fs(11), weight: .medium))
                    .foregroundStyle(.secondary)
            case .unknown, .allowed:
                CameraPreview(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            overlayButton("xmark", label: "Close Mirror", action: close)
                .padding(7)
        }
        .overlay(alignment: .bottomLeading) {
            // More than one camera (say an iPhone and OBS): switch between them.
            if camera.cameras.count > 1 {
                Button {
                    camera.switchCamera()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: fs(9), weight: .bold))
                        Text(camera.currentName ?? "Camera")
                            .font(.system(size: fs(9.5), weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Switch camera")
                .padding(7)
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private func overlayButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fs(8), weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.45)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

struct EmptyPlayerView: View {
    let media: MediaController

    private var openButtons: some View {
        ForEach(PlayerApp.allCases.filter { $0.appURL != nil }, id: \.self) { app in
            Button {
                media.launch(app)
            } label: {
                Text("Open \(app.rawValue)")
                    .font(.system(size: fs(11), weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(image: nil, size: 84, corner: 12)
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing playing")
                    .font(.system(size: fs(13), weight: .semibold))
                // Side by side when they fit, stacked in a narrow panel.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { openButtons }
                    VStack(alignment: .leading, spacing: 6) { openButtons }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ProgressBar: View {
    let media: MediaController
    @Environment(NotchUIState.self) private var ui
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(media.track?.duration ?? 0, 1)
            let position = media.position(at: context.date)
            let fraction = ui.dragFraction ?? min(max(position / duration, 0), 1)
            let active = ui.progressHovering || ui.dragFraction != nil
            // The album color pops on black; on light glass a neutral fill reads better.
            let fill = colorScheme == .dark ? media.accent : Color.primary

            VStack(spacing: 1) {
                // The visible bar is thin, the grab area a comfortable 14pt tall.
                // It thickens under the pointer, and while dragging it tracks 1:1.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(active ? 0.2 : 0.13))
                        Capsule()
                            .fill(fill)
                            .frame(width: max(geo.size.width * fraction, 5))
                    }
                    .frame(height: active ? 7 : 5)
                    .frame(maxHeight: .infinity)
                    .animation(.easeOut(duration: 0.15), value: active)
                    .contentShape(Rectangle())
                    .onHover { ui.progressHovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                ui.dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { value in
                                let f = min(max(value.location.x / geo.size.width, 0), 1)
                                media.seek(to: f * duration)
                                ui.dragFraction = nil
                            }
                    )
                }
                .frame(height: 14)

                HStack {
                    Text(timeString(fraction * duration))
                    Spacer()
                    Text("-" + timeString(duration - fraction * duration))
                }
                .font(.system(size: fs(9.5), weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ControlButton: View {
    let id: String
    let symbol: String
    var size: CGFloat = 15
    let action: () -> Void
    @Environment(NotchUIState.self) private var ui

    private var hovering: Bool { ui.hoveredControl == id }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fs(size), weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                // Play and pause morph into each other (also when the music
                // app changes state on its own).
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: symbol)
                .frame(width: fs(size + 18), height: fs(size + 14))
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .animation(.easeOut(duration: 0.15), value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressedScale: 0.88))
        .onHover { inside in
            if inside { ui.hoveredControl = id } else if ui.hoveredControl == id { ui.hoveredControl = nil }
        }
    }
}

/// Feedback on press, not on release: shrinks instantly while held and springs
/// back on release. Scales between 0.88 and 0.97, never from zero.
struct PressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(configuration.isPressed
                       ? .easeOut(duration: 0.1)
                       : .spring(response: 0.3, dampingFraction: 0.75),
                       value: configuration.isPressed)
    }
}

// MARK: - Notification list

/// Notifications grouped by app, newest first, like iPhone: several from
/// the same app become one stack that opens with a click.
struct AlertGroup: Identifiable {
    let key: String
    let alerts: [NotchAlert]
    var id: String { key }
}

struct NotificationListView: View {
    let alerts: AlertCenter
    /// Other apps' Live Activities sit at the top of the list and scroll
    /// with the notifications, so they never crowd them out.
    let liveActivities: LiveActivityMonitor
    @Environment(NotchUIState.self) private var ui

    private var groups: [AlertGroup] {
        var order: [String] = []
        var byKey: [String: [NotchAlert]] = [:]
        for alert in alerts.history {
            let key = alert.bundleID?.lowercased() ?? alert.id.uuidString
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(alert)
        }
        return order.map { AlertGroup(key: $0, alerts: byKey[$0] ?? []) }
    }

    private func clear(_ ids: [UUID]) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { alerts.dismiss(ids) }
    }

    var body: some View {
        if alerts.history.isEmpty && liveActivities.items.isEmpty {
            // Shown only when it fits whole: with timers, calls or meetings
            // filling the column it steps aside instead of being cut off.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: fs(18)))
                    Text("No Notifications")
                        .font(.system(size: fs(11), weight: .medium))
                }
                .padding(.vertical, 4)
                Color.clear.frame(height: 0)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(liveActivities.items) { activity in
                        ExternalActivityCard(activity: activity,
                                             onOpen: { liveActivities.open(activity.id) },
                                             onDismiss: {
                                                 withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                                     liveActivities.dismiss(activity.id)
                                                 }
                                             })
                            .padding(.bottom, 4)
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                    }
                    ForEach(groups) { group in
                        if group.alerts.count == 1, let alert = group.alerts.first {
                            row(alert)
                        } else {
                            NotificationGroupView(
                                group: group,
                                expanded: ui.expandedStacks.contains(group.key),
                                setExpanded: { open in
                                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                        if open { ui.expandedStacks.insert(group.key) }
                                        else { ui.expandedStacks.remove(group.key) }
                                    }
                                },
                                open: { alerts.open($0) },
                                clear: { clear($0) })
                            .transition(.asymmetric(insertion: .opacity,
                                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            // Fade the edges where rows scroll away, instead of a hard cut.
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .transition(.opacity)
        }
    }

    private func row(_ alert: NotchAlert) -> some View {
        NotificationRow(alert: alert,
                        action: { alerts.open(alert) },
                        clear: { clear([alert.id]) })
        .transition(.asymmetric(insertion: .opacity,
                                removal: .move(edge: .trailing).combined(with: .opacity)))
    }
}

/// Several notifications from one app. Stacked, the newest is on top with
/// the others tucked behind it, peeking out below, and a count. Click it and
/// they roll down out from behind it into a list, like iPhone; Show Less
/// rolls them back up. Swipe or the x clears them all while stacked.
struct NotificationGroupView: View {
    let group: AlertGroup
    let expanded: Bool
    let setExpanded: (Bool) -> Void
    let open: (NotchAlert) -> Void
    let clear: ([UUID]) -> Void
    @Environment(NotchUIState.self) private var ui

    private var ids: [UUID] { group.alerts.map(\.id) }

    /// The whole stack follows the fingers when its top card is swiped.
    private var stackSwipe: CGFloat {
        guard !expanded, let top = group.alerts.first, ui.swipingAlert == top.id else { return 0 }
        return ui.swipeOffset
    }

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                StackHeader(title: group.alerts.first?.appName ?? group.alerts.first?.title ?? "",
                            collapse: { setExpanded(false) },
                            clear: { clear(ids) })
                    .padding(.bottom, 2)
                    .transition(.opacity)
            }
            ForEach(Array(group.alerts.enumerated()), id: \.element.id) { index, alert in
                card(alert, index: index)
            }
        }
        // Room for the cards peeking out below the stack.
        .padding(.bottom, expanded ? 0 : 7)
    }

    @ViewBuilder
    private func card(_ alert: NotchAlert, index: Int) -> some View {
        let isTop = index == 0
        // Tucked: behind the top card, its layout height folded to zero so it
        // sits there, a little narrower and lower per layer. Expanding unfolds
        // the height, so each card slides down into its own place.
        let tucked = !expanded && !isTop
        let depth = CGFloat(min(index, 2))
        NotificationRow(alert: alert,
                        action: expanded ? { open(alert) } : { setExpanded(true) },
                        clear: expanded ? { clear([alert.id]) } : { clear(ids) },
                        carded: !expanded,
                        contentOpacity: tucked ? 0 : 1,
                        moreCount: isTop && !expanded ? group.alerts.count - 1 : nil,
                        stackIDs: isTop && !expanded ? ids : nil,
                        cardShade: tucked ? (index == 1 ? 0.07 : 0.05) : nil)
            .scaleEffect(x: tucked ? 1 - 0.055 * depth : 1, anchor: .center)
            .frame(height: tucked ? 0 : nil, alignment: .bottom)
            .offset(x: tucked ? stackSwipe : 0, y: tucked ? 3.5 * depth : 0)
            .opacity(tucked && index > 2 ? 0 : 1)
            .zIndex(Double(group.alerts.count - index))
            .allowsHitTesting(!tucked)
            .padding(.top, expanded && !isTop ? 2 : 0)
            .transition(.asymmetric(insertion: .opacity,
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
    }
}

/// Above an opened stack: the app's name, Show Less, and clear all.
struct StackHeader: View {
    let title: String
    let collapse: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: fs(11), weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Show Less", action: collapse)
                .buttonStyle(.plain)
                .font(.system(size: fs(10), weight: .medium))
                .foregroundStyle(.secondary)
            Button(action: clear) {
                Image(systemName: "xmark")
                    .font(.system(size: fs(7.5), weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Clear these notifications")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

/// A notification in the list. Swipe it sideways with two fingers to clear
/// it, or hover and click the small x on its icon, like Notification Center.
struct NotificationRow: View {
    let alert: NotchAlert
    let action: () -> Void
    let clear: () -> Void
    /// Drawn as a card (the top of a stack) rather than a plain row.
    var carded = false
    /// Hidden content, card kept (a card tucked behind a stack's top).
    var contentOpacity: Double = 1
    /// "3 more", on the top card of a closed stack.
    var moreCount: Int? = nil
    /// The whole stack, so a swipe or the x clears all of it.
    var stackIDs: [UUID]? = nil
    /// The fill of a tucked card, fainter the deeper it sits.
    var cardShade: Double? = nil
    @Environment(NotchUIState.self) private var ui

    private var hovering: Bool { ui.hoveredAlert == alert.id }
    private var offset: CGFloat { ui.swipingAlert == alert.id ? ui.swipeOffset : 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            row
                // Follows the fingers, fading as it goes.
                .offset(x: offset)
                .opacity(1 - min(0.7, Double(abs(offset)) / 260))
            if hovering && offset == 0 {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: fs(7.5), weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Clear notification")
                .offset(x: 1, y: -1)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { inside in
            if inside {
                ui.hoveredAlert = alert.id
                ui.hoveredStack = stackIDs
            } else if ui.hoveredAlert == alert.id {
                ui.hoveredAlert = nil
                ui.hoveredStack = nil
            }
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AlertIcon(alert: alert, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(alert.title)
                            .font(.system(size: fs(11.5), weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(alert.date.notchTimestamp)
                            .font(.system(size: fs(9.5)))
                            .foregroundStyle(.tertiary)
                    }
                    if alert.detail != nil || moreCount != nil {
                        HStack(spacing: 6) {
                            if let detail = alert.detail {
                                Text(detail)
                                    .font(.system(size: fs(10.5)))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if let moreCount {
                                Text("\(moreCount) more")
                                    .font(.system(size: fs(9.5), weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .transition(.opacity)
                            }
                        }
                    }
                }
            }
            .opacity(contentOpacity)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(cardShade ?? (carded ? (hovering ? 0.12 : 0.09) : (hovering ? 0.08 : 0)))))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(pressedScale: 0.97))
        // A stack's top card always works: it opens the stack.
        .disabled(!carded && alert.bundleID == nil && alert.fileURL == nil)
    }
}

// MARK: - Shared

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }
        }
        // Artwork that loads a moment after the song fades in.
        .animation(.easeInOut(duration: 0.25), value: image.map(ObjectIdentifier.init))
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

extension Date {
    /// "now" for the first minute, then the time, like macOS notifications.
    var notchTimestamp: String {
        abs(timeIntervalSinceNow) < 60 ? "now" : formatted(date: .omitted, time: .shortened)
    }
}

private func timeString(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Other apps' Live Activities

/// The app's icon when it's on this Mac; otherwise (an iPhone app) its
/// initial on a tile.
struct ExternalAppIcon: View {
    let activity: ExternalActivity
    let size: CGFloat

    var body: some View {
        if let icon = activity.icon {
            // A Mac app's icon comes shaped already; an iPhone app's is a
            // plain square, so it gets iOS's rounded corners (about 22.4% of
            // the side, on Apple's continuous curve).
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: activity.iconIsShaped ? 0 : size * 0.2237, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Self.tint(for: activity.bundleID).opacity(0.95), Self.tint(for: activity.bundleID).opacity(0.7)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Text(String(activity.appName.prefix(1)).uppercased())
                        .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                )
                .frame(width: size, height: size)
        }
    }

    /// A steady colour per app.
    static func tint(for bundleID: String) -> Color {
        let colors: [Color] = [.green, .blue, .orange, .pink, .purple, .teal, .indigo, .red]
        let hash = bundleID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[hash % colors.count]
    }
}

/// A Live Activity's value. A countdown ticks every second ("1:48:14");
/// anything else is the app's own words.
struct ActivityValueText: View {
    let text: String
    let countdown: Date?

    var body: some View {
        if let countdown {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(countdownClock(countdown.timeIntervalSince(context.date)))
                    .monospacedDigit()
            }
        } else {
            Text(text)
        }
    }
}

/// In the pill: the app's icon, its line ("Inter 2 – 1 Milan") and the live
/// value (the minute, in green). Dimmed with a clock once it's out of date.
struct ExternalActivityView: View {
    let activity: ExternalActivity
    let notchWidth: CGFloat
    let height: CGFloat
    let layout: CompactLayout
    let showsTitle: Bool

    var body: some View {
        CompactActivityRow(title: activity.title, notchWidth: notchWidth, height: height,
                           layout: layout, showsTitle: showsTitle, shorter: activity.shorterTitles,
                           subtitle: activity.detail) {
            // A touch smaller than its spot: an app icon is a solid tile edge
            // to edge, and at full size it looks bigger than the song's
            // artwork in the same place.
            ExternalAppIcon(activity: activity, size: (layout.artworkSize * 0.84).rounded())
        } trailing: {
            HStack(spacing: 4) {
                if activity.isStale {
                    Image(systemName: "clock")
                        .font(.system(size: layout.titleSize * 0.8, weight: .semibold))
                }
                // Beside a notch there's no room for the title: the score
                // comes in front of the minute.
                if !showsTitle, case .match = activity.display, let short = activity.short {
                    Text(short).foregroundStyle(activity.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
                }
                if case .match(let match) = activity.display, let minute = match.minute {
                    // A live match: the minute's tick blinks, like a scoreboard.
                    LiveMinute(minute: minute, live: !activity.isStale)
                } else if case .general(let general) = activity.display, !general.isTask {
                    // A delivery, a ride: the app's own short words ("5min")
                    // in its colour, with the order's progress as a ring.
                    if let value = general.value {
                        ActivityValueText(text: value, countdown: general.countdown)
                            .foregroundStyle(activity.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(activity.accent))
                            .contentTransition(.numericText())
                    }
                    if general.progress != nil || general.isComplete {
                        TaskProgress(general: general, size: layout.titleSize * 1.15, showsPercent: false,
                                     tint: activity.accent, showsNumber: false)
                    }
                } else if case .general(let general) = activity.display, general.showsProgressRing {
                    // A scan, a cleanup, a download: a ring that fills, then a tick.
                    TaskProgress(general: general, size: layout.titleSize * 1.15, showsPercent: true)
                } else if let value = activity.value {
                    Text(value)
                        .foregroundStyle(activity.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(.secondary)
        }
        .opacity(activity.isStale ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.3), value: activity.isStale)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: activity.value)
    }
}

/// In the panel: a card for a match (competition, both teams with their
/// score and red cards, the minute) or a row for any other app. A click opens
/// the app, or iPhone Mirroring for an iPhone app.
struct ExternalActivityCard: View {
    let activity: ExternalActivity
    let onOpen: () -> Void
    /// Hides it in Brim until it ends (macOS keeps showing it).
    let onDismiss: () -> Void
    @Environment(NotchUIState.self) private var ui

    private var hovering: Bool { ui.hoveredLiveActivity == activity.id }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch activity.display {
                case .match(let match): matchCard(match)
                case .general(let general): generalRow(general)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            // An app that names its card's colour (Duolingo's red "last
            // chance") gets a wash of it, like its own card; others stay plain.
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(activity.tint != nil && !activity.isStale ? activity.accent.opacity(0.2) : Color.primary.opacity(0.06)))
            .opacity(activity.isStale ? 0.6 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .help(activity.fromiPhone ? "Open in iPhone Mirroring" : "Open \(activity.appName)")
            .contextMenu {
                Button("Open \(activity.fromiPhone ? "in iPhone Mirroring" : activity.appName)", action: onOpen)
                Button("Hide This Live Activity", action: onDismiss)
            }
            // The same x as a notification's, on hover.
            if hovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: fs(7.5), weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Hide this Live Activity")
                .offset(x: 1, y: -1)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { inside in
            if inside { ui.hoveredLiveActivity = activity.id }
            else if ui.hoveredLiveActivity == activity.id { ui.hoveredLiveActivity = nil }
        }
    }

    private var minuteColor: AnyShapeStyle {
        activity.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green)
    }

    private func matchCard(_ match: ExternalActivity.Match) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ExternalAppIcon(activity: activity, size: 14)
                // The icon says which app; the line is the competition, shrunk
                // a little rather than cut when it's long.
                Text(match.competition ?? activity.appName)
                    .font(.system(size: fs(10), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                if activity.isStale {
                    Image(systemName: "clock").font(.system(size: fs(9), weight: .semibold)).foregroundStyle(.secondary)
                }
                if let minute = match.minute {
                    LiveMinute(minute: minute, live: !activity.isStale)
                        .font(.system(size: fs(10.5), weight: .bold).monospacedDigit())
                }
            }
            team(match.home, match.homeScore, reds: match.homeRed)
            team(match.away, match.awayScore, reds: match.awayRed)
        }
    }

    private func team(_ name: String, _ score: Int, reds: Int) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: fs(11.5), weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            ForEach(0..<min(reds, 3), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 5, height: 7)
            }
            Spacer(minLength: 4)
            Text("\(score)")
                .font(.system(size: fs(13), weight: .heavy).monospacedDigit())
                .contentTransition(.numericText())
        }
    }

    /// Like the app's own Live Activity on iPhone: the main line in the
    /// app's colour, what's happening under it, and the progress bar.
    private func generalRow(_ general: ExternalActivity.General) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                ExternalAppIcon(activity: activity, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(general.title)
                        .font(.system(size: fs(12), weight: .bold))
                        .foregroundStyle(activity.isStale || general.isTask ? AnyShapeStyle(.primary) : AnyShapeStyle(activity.accent))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(general.subtitle ?? activity.appName)
                        .font(.system(size: fs(10.5)))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if activity.isStale {
                    Image(systemName: "clock").font(.system(size: fs(10), weight: .semibold)).foregroundStyle(.secondary)
                }
                if general.isTask, general.showsProgressRing {
                    TaskProgress(general: general, size: 22, showsPercent: false)
                } else if general.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: fs(16), weight: .semibold))
                        .foregroundStyle(activity.accent)
                } else if let value = general.value {
                    ActivityValueText(text: value, countdown: general.countdown)
                        .font(.system(size: fs(12), weight: .semibold).monospacedDigit())
                        .foregroundStyle(general.isTask ? minuteColor : AnyShapeStyle(activity.accent))
                }
            }
            if !general.isTask, let progress = general.progress {
                ActivityProgressBar(fraction: general.isComplete ? 1 : progress,
                                    tint: activity.isStale ? .secondary : activity.accent)
            }
        }
    }
}

/// "61'" with the tick blinking while the match is live (still with Reduce
/// Motion, or once the data is out of date).
struct LiveMinute: View {
    let minute: Int
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Text("\(minute)")
                .contentTransition(.numericText())
            if live && !reduceMotion {
                PhaseAnimator([true, false]) { on in
                    Text("'").opacity(on ? 1 : 0.12)
                } animation: { _ in .easeInOut(duration: 0.55) }
            } else {
                Text("'")
            }
        }
        .foregroundStyle(live ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: minute)
    }
}

/// The circle's ring for another app's activity; a live match's breathes.
/// An order's or a ride's progress, as the app draws it on iPhone: a
/// rounded bar in its colour.
struct ActivityProgressBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18))
                Capsule().fill(tint)
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.5), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent")
    }
}

/// A task's progress, the way the system draws it: a thin ring that fills
/// clockwise with the percentage beside it (or inside, in the panel), and a
/// check mark that pops in when it's done.
struct TaskProgress: View {
    let general: ExternalActivity.General
    let size: CGFloat
    /// Beside the ring (the pill); otherwise inside it (the panel).
    let showsPercent: Bool
    var tint: Color = .green
    /// The number inside the ring (tasks); a delivery's ring is just a ring.
    var showsNumber = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { general.isComplete ? 1 : min(1, max(0, general.progress ?? 0)) }
    private var percent: String { "\(Int((fraction * 100).rounded(.down)))%" }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: size * 0.12)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if general.isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.48, weight: .bold))
                        .foregroundStyle(tint)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else if !showsPercent, showsNumber {
                    Text("\(Int((fraction * 100).rounded(.down)))")
                        .font(.system(size: size * 0.36, weight: .semibold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: size, height: size)
            if showsPercent, !general.isComplete {
                Text(percent)
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.7), value: general.isComplete)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(general.isComplete ? "Done" : "\(percent) done")
    }
}

struct LiveRing: View {
    let progress: Double
    let tint: Color
    let breathing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if breathing && !reduceMotion {
            PhaseAnimator([true, false]) { bright in
                EdgeRing(progress: progress, tint: tint).opacity(bright ? 1 : 0.45)
            } animation: { _ in .easeInOut(duration: 1.3) }
        } else {
            EdgeRing(progress: progress, tint: tint)
        }
    }
}

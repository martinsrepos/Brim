import AppKit
import SwiftUI

/// Borderless, transparent panel that floats above the menu bar on every Space.
final class NotchPanel: NSPanel {
    // Never take keyboard focus away from the app you're working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a button work even though the panel is never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchWindowController: NSObject {
    /// One island per display that shows one (Settings > Displays): an everyday
    /// window, where Liquid Glass can blur what's behind it, and a copy on the
    /// lock screen layer that only draws while the Mac is locked.
    private struct Island {
        let panel: NotchPanel
        let lockPanel: NotchPanel
    }

    private var islands: [CGDirectDisplayID: Island] = [:]
    private let vm: NotchViewModel
    private let media: MediaController
    private let alerts: AlertCenter
    /// The display the pointer is using: its island hovers, opens and takes clicks.
    private var screen: NSScreen?
    private var builtFor: NotchViewModel.DisplayChoice?
    private var timer: Timer?
    private var fullScreenTimer: Timer?
    /// League of Legends is in front: hovering does nothing (no panel, and
    /// clicks go to the game). Banners still show.
    private var hoverOff = false
    private var hoverStart: Date?
    private var lastInside = Date()
    private var revealedAt = Date.distantPast
    private var scrollMonitor: Any?
    /// The current trackpad gesture: nil until it's clear whether it's a
    /// sideways swipe on a notification (true) or a scroll (false).
    private var swipeDecided: Bool?
    /// After a swipe, the trackpad's coasting events are swallowed too.
    private var swallowMomentum = false
    /// The pointer is over a banner: it takes the trackpad, so a swipe up can
    /// flick the banner away.
    private var overBanner = false
    /// How far the fingers have moved up in the current swipe on a banner.
    private var bannerSwipe: CGFloat = 0
    /// After flicking a banner away, the pill under the pointer doesn't open
    /// until the pointer has left it.
    private var holdHoverUntilLeave = false
    /// Fingers this far up flick the banner away.
    private static let bannerSwipeThreshold: CGFloat = 24
    /// With a mouse: where a click on a banner started, while the button is
    /// held. Dragging up this far flicks the banner away.
    private var bannerDragStart: CGFloat?
    private static let bannerDragThreshold: CGFloat = 16

    /// A swipe this far clears the notification; less springs it back.
    private static let swipeThreshold: CGFloat = 90

    init(vm: NotchViewModel, media: MediaController, alerts: AlertCenter) {
        self.vm = vm
        self.media = media
        self.alerts = alerts
        super.init()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        // Two-finger swipe sideways on a notification clears it, like
        // Notification Center. Up and down still scroll the list.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Over the teleprompter, any wheel or trackpad scrolls the script
            // by hand: down goes on, up goes back.
            let precise = event.hasPreciseScrollingDeltas, wheel = event.scrollingDeltaY
            let prompterScrolled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.vm.prompter.isActive, self.vm.prompter.isHovered else { return false }
                let prompter = self.vm.prompter
                prompter.scroll(by: precise ? -wheel : -wheel * prompter.lineHeight / 3)
                return true
            }
            if prompterScrolled { return nil }
            guard event.hasPreciseScrollingDeltas else { return event }  // a mouse wheel
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            // Follow the fingers whichever way "natural scrolling" is set.
            let fingers = event.isDirectionInvertedFromDevice ? dx : -dx
            // Positive when the fingers move up, whichever way scrolling is set.
            let fingersUp = event.isDirectionInvertedFromDevice ? -dy : dy
            let phase = event.phase.rawValue, momentum = event.momentumPhase.rawValue
            let consumed = MainActor.assumeIsolated {
                self?.handleScroll(fingers: fingers, fingersUp: fingersUp, dx: dx, dy: dy,
                                   phase: phase, momentum: momentum) ?? false
            }
            return consumed ? nil : event
        }
    }

    private var activePanel: NotchPanel? {
        guard let screen, let id = Self.displayID(of: screen) else { return nil }
        return islands[id]?.panel
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The built-in notch screen if there is one, otherwise the menu bar screen.
    private var mainScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
    }

    private var pointerScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private func handleScroll(fingers: CGFloat, fingersUp: CGFloat, dx: CGFloat, dy: CGFloat,
                              phase: UInt, momentum: UInt) -> Bool {
        let ui = vm.ui
        if momentum != 0 {
            if NSEvent.Phase(rawValue: momentum).contains(.ended) {
                defer { swallowMomentum = false }
                return swallowMomentum
            }
            return swallowMomentum
        }
        let phase = NSEvent.Phase(rawValue: phase)
        if phase.contains(.began) {
            swipeDecided = nil
            swallowMomentum = false
            bannerSwipe = 0
            if overBanner, !vm.isExpanded { hoverStart = Date() }   // a swipe, not a hover
            return overBanner && !vm.isExpanded
        }

        // Swipe up on a banner flicks it away, like on iPhone. It stays in
        // the notifications list.
        if !vm.isExpanded, overBanner, vm.mode == .banner {
            hoverStart = Date()   // the panel waits while you swipe
            if phase.contains(.ended) || phase.contains(.cancelled) {
                bannerSwipe = 0
                return true
            }
            bannerSwipe += fingersUp
            if bannerSwipe > Self.bannerSwipeThreshold {
                bannerSwipe = 0
                swallowMomentum = true
                dismissBanner()
            }
            return true
        }
        guard vm.isExpanded else { return false }

        if swipeDecided == nil, dx != 0 || dy != 0 {
            if abs(dx) > abs(dy) * 1.5, let hovered = ui.hoveredAlert {
                swipeDecided = true
                ui.swipingAlert = hovered
                // A closed stack goes as a whole.
                ui.swipingStack = ui.hoveredStack?.first == hovered ? ui.hoveredStack : nil
                ui.swipeOffset = 0
            } else {
                swipeDecided = false
            }
        }
        guard swipeDecided == true, let id = ui.swipingAlert else { return false }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            swipeDecided = nil
            swallowMomentum = true
            if abs(ui.swipeOffset) > Self.swipeThreshold, !phase.contains(.cancelled) {
                let away: CGFloat = ui.swipeOffset < 0 ? -480 : 480
                withAnimation(.easeOut(duration: 0.18)) { ui.swipeOffset = away }
                let stack = ui.swipingStack
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    if let stack { alerts.dismiss(stack) } else { alerts.dismiss(id) }
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { ui.swipeOffset = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    if ui.swipingAlert == id {
                        ui.swipingAlert = nil
                        ui.swipingStack = nil
                        ui.swipeOffset = 0
                    }
                }
            }
            return true
        }
        ui.swipeOffset += fingers
        return true
    }

    /// Just above the menu bar: high enough for every normal and full-screen
    /// app.
    private static let normalLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    /// Borderless, transparent, above the menu bar, on every Space and over
    /// full-screen apps. Ignores the mouse until hovered.
    private static func makePanel<Content: View>(_ root: Content) -> NotchPanel {
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: NotchViewModel.canvas),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.normalLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: NotchViewModel.canvas)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// `display` is set only when several islands show at once, so each knows
    /// whether it's the one the pointer opened.
    private func makeIsland(display: CGDirectDisplayID?) -> Island {
        let island = Island(
            panel: Self.makePanel(IslandRootView(vm: vm, media: media, alerts: alerts,
                                                 onLockScreen: false, displayID: display)),
            lockPanel: Self.makePanel(IslandRootView(vm: vm, media: media, alerts: alerts,
                                                     onLockScreen: true, displayID: display)))
        island.panel.orderFrontRegardless()
        island.lockPanel.orderFrontRegardless()
        // Keep a copy visible over the lock screen (see LockScreen.swift).
        _ = LockScreenSpace.add(island.lockPanel)
        return island
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let c = NotchViewModel.canvas
        return NSRect(x: (screen.frame.midX - c.width / 2).rounded(),
                      y: screen.frame.maxY - c.height,
                      width: c.width, height: c.height)
    }

    func show() {
        rebuildIslands()

        // Hover detection: poll the mouse, 30 times a second near the top of
        // the screen and 8 times a second elsewhere (see setTickRate). Works
        // even though the panel ignores mouse events while collapsed.
        setTickRate(fast: true)

        // Full-screen check: every 2 seconds, and right away when apps or
        // Spaces change (which is when it usually matters).
        let f = Timer(timeInterval: 2.0, target: self, selector: #selector(updateFullScreen),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(f, forMode: .common)
        fullScreenTimer = f
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(updateFullScreen),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(updateFullScreen),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    /// Puts an island on each display Settings asks for: the main one, the
    /// one with the pointer (it follows you), or all of them.
    private func rebuildIslands() {
        for island in islands.values {
            island.panel.orderOut(nil)
            island.lockPanel.orderOut(nil)
        }
        islands.removeAll()
        builtFor = vm.displayChoice
        screenSignature = Self.currentScreenSignature

        let screens: [NSScreen]
        switch vm.displayChoice {
        case .main: screens = mainScreen.map { [$0] } ?? []
        case .pointer: screens = (pointerScreen ?? mainScreen).map { [$0] } ?? []
        case .all: screens = NSScreen.screens
        }
        let several = screens.count > 1
        for s in screens {
            guard let id = Self.displayID(of: s) else { continue }
            let island = makeIsland(display: several ? id : nil)
            island.panel.setFrame(frame(on: s), display: true)
            island.lockPanel.setFrame(frame(on: s), display: true)
            islands[id] = island
        }
        // The island's shape comes from the main screen (its notch, if any),
        // or from the display it's on when it follows the pointer.
        if let metrics = vm.displayChoice == .pointer ? screens.first : mainScreen {
            vm.updateMetrics(for: metrics)
        }
        let start = screens.first { $0 == pointerScreen } ?? screens.first { $0 == mainScreen } ?? screens.first
        makeActive(start)
    }

    /// The display the pointer is using takes hover, clicks and the reveal
    /// over full-screen apps; the others stay compact.
    private func makeActive(_ newScreen: NSScreen?) {
        let previous = activePanel
        screen = newScreen
        if let previous, previous !== activePanel { previous.ignoresMouseEvents = true }
        hoverStart = nil
        guard let newScreen, let id = Self.displayID(of: newScreen) else { return }
        if vm.activeDisplay != id { vm.activeDisplay = id }
        let fullScreen = vm.fullScreenDisplays.contains(id)
        if vm.isFullScreen != fullScreen { vm.isFullScreen = fullScreen }
        if vm.isRevealed { vm.isRevealed = false }
    }

    /// Pointer mode: the one island moves to the display you went to.
    private func moveIsland(to newScreen: NSScreen) {
        guard let island = islands.values.first, let id = Self.displayID(of: newScreen) else { return }
        islands = [id: island]
        island.panel.setFrame(frame(on: newScreen), display: true)
        island.lockPanel.setFrame(frame(on: newScreen), display: true)
        vm.updateMetrics(for: newScreen)
        makeActive(newScreen)
    }

    /// The front app is full screen on a display when one of its windows covers
    /// it. Window bounds are readable without any permission (only window
    /// titles would need Screen Recording).
    ///
    /// Games often go further than a normal full-screen app: their window sits
    /// at a raised window level, or the game captures the display, which puts
    /// a system "shield" window over everything (League of Legends' full
    /// screen mode does one or the other). Either way the island would be
    /// hidden underneath, banners included. So while that's the case, the
    /// island rises just above the game, and drops back to its normal level
    /// afterwards.
    @objc private func updateFullScreen() {
        // Displays off: nothing to arrange. Checked again when they wake.
        guard !QuietState.shared.isDark else { return }
        Diag.count("window.fullScreenCheck")
        // The lock screen covers every display at a very high level too; it's
        // not a game. While locked (and while the lock opens) the island
        // keeps its normal level and is never tucked away, so the lock shows.
        guard vm.lock.state == .unlocked else {
            raiseAbove(Int.min)
            hoverOff = false
            if !vm.fullScreenDisplays.isEmpty { vm.fullScreenDisplays = [] }
            if vm.isFullScreen { vm.isFullScreen = false }
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        let shieldLevel = Int(CGShieldingWindowLevel())
        // The front app's windows at any level, plus a display capture's shield.
        let coverCandidates: [(rect: CGRect, layer: Int)] = windows.compactMap { window in
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let owner = window[kCGWindowOwnerPID as String] as? pid_t
            let isFront = owner == front.processIdentifier
            let isShield = layer >= shieldLevel && owner != ProcessInfo.processInfo.processIdentifier
            guard isFront || isShield,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (rect, layer)
        }
        var covered: Set<CGDirectDisplayID> = []
        var highestCover = Int.min
        for s in NSScreen.screens {
            guard let id = Self.displayID(of: s) else { continue }
            let display = CGDisplayBounds(id)
            let covers = coverCandidates.filter { candidate in
                let rect = candidate.rect
                return abs(rect.minX - display.minX) < 1 && abs(rect.minY - display.minY) < 1
                    && abs(rect.width - display.width) < 1 && abs(rect.height - display.height) < 1
            }
            guard !covers.isEmpty else { continue }
            covered.insert(id)
            highestCover = max(highestCover, covers.map(\.layer).max() ?? 0)
        }
        raiseAbove(highestCover)
        // Some games keep the island in view instead of tucking it away, and
        // switch hovering off so the top of the screen stays theirs.
        // Only while it's actually full screen; its windowed modes behave like
        // any other app.
        let game = !covered.isEmpty && Self.staysVisible(over: front)
        if game { covered.removeAll() }
        if game != hoverOff {
            let path = front.executableURL?.path ?? front.bundleIdentifier ?? "?"
            Diag.event("League mode \(game ? "on" : "off")")
            appLog.info("League mode \(game ? "on" : "off", privacy: .public) (front app: \(path, privacy: .public))")
        }
        hoverOff = game
        if vm.fullScreenDisplays != covered { vm.fullScreenDisplays = covered }
        let active = screen.flatMap(Self.displayID(of:)).map { covered.contains($0) } ?? false
        guard vm.isFullScreen != active else { return }
        vm.isFullScreen = active
        vm.isRevealed = false
    }

    /// The full-screen app over which the island stays in view (above the
    /// game) instead of tucking away: League of Legends. It runs as two apps
    /// inside League of Legends.app: the client (lobby, champion select),
    /// .../Contents/LoL/LeagueClient.app, and during a match the game itself,
    /// a separate app in .../Contents/LoL/Game/. Either counts, wherever
    /// League is installed, and only while it's full screen (checked by the
    /// caller).
    private static func staysVisible(over app: NSRunningApplication) -> Bool {
        let paths = [app.executableURL, app.bundleURL].compactMap { $0?.resolvingSymlinksInPath().path }
        return paths.contains { $0.contains("League of Legends.app/") }
    }

    /// Puts the islands one level above a window covering the screen when that
    /// window sits at or above their normal level (a game), or back to normal.
    private func raiseAbove(_ coverLayer: Int) {
        let target = coverLayer >= Self.normalLevel.rawValue
            ? NSWindow.Level(rawValue: coverLayer + 1)
            : Self.normalLevel
        for island in islands.values where island.panel.level != target {
            island.panel.level = target
            if target != Self.normalLevel {
                appLog.info("Island raised above a full-screen game (window level \(coverLayer))")
            }
        }
    }

    /// The displays and where they are, the last time the islands were built.
    private var screenSignature = ""

    private static var currentScreenSignature: String {
        NSScreen.screens.map { screen in
            "\(displayID(of: screen) ?? 0):\(NSStringFromRect(screen.frame))"
        }.joined(separator: "|")
    }

    /// A display was added, removed, moved or resized. macOS also posts this
    /// when a display merely sleeps or wakes; then nothing has changed and the
    /// islands stay as they are.
    private var pendingRebuild: DispatchWorkItem?

    /// Waking displays often report two changes in a row: wait half a second
    /// and rebuild once.
    @objc private func screensChanged() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let signature = Self.currentScreenSignature
                guard signature != self.screenSignature else { return }
                Diag.event("Displays changed: rebuilding islands")
                self.rebuildIslands()
            }
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @objc private func tick() {
        // Displays off: no pointer to follow (the panel is closed first, below,
        // if the Mac locked meanwhile).
        let dark = QuietState.shared.isDark
        if dark, !vm.isExpanded {
            setTickRate(fast: false)
            return
        }
        Diag.count("window.tick")
        // The teleprompter stays out of screen shares and recordings (if set).
        let sharing: NSWindow.SharingType = vm.prompter.isActive && vm.prompter.hidesFromSharing ? .none : .readOnly
        for island in islands.values where island.panel.sharingType != sharing {
            island.panel.sharingType = sharing
        }
        if builtFor != vm.displayChoice { rebuildIslands() }
        vm.forgetFinishedChoice()

        // Several displays: whichever one the pointer moves to becomes the
        // active island (pointer mode moves the island there). Not while one
        // is open, so the panel doesn't jump away under you.
        if vm.displayChoice != .main, !vm.isExpanded, let here = pointerScreen, here != screen,
           let id = Self.displayID(of: here) {
            if vm.displayChoice == .pointer {
                moveIsland(to: here)
            } else if islands[id] != nil {
                makeActive(here)
            }
        }
        guard let screen, let panel = activePanel else { return }
        // Every early return below hands the trackpad back if a banner had it.
        func leaveBanner() {
            guard overBanner else { return }
            overBanner = false
            if !vm.isExpanded { panel.ignoresMouseEvents = true }
        }
        // While locked, nothing opens: the history and controls stay private.
        guard vm.lock.state == .unlocked else {
            leaveBanner()
            if vm.isExpanded { setExpanded(false) }
            hoverStart = nil
            return
        }
        if dark { setExpanded(false); return }

        if hoverOff {
            leaveBanner()
            if vm.isExpanded { setExpanded(false) }
            if vm.ui.hoveringBubble { vm.ui.hoveringBubble = false }
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            hoverStart = nil
            return
        }

        let mouse = NSEvent.mouseLocation
        let top = screen.frame.maxY
        let midX = screen.frame.midX

        // The teleprompter is on: no panel, and the pointer can reach its
        // controls (they show while it's over the prompter).
        if vm.mode == .prompter {
            leaveBanner()
            if vm.isExpanded { setExpanded(false) }
            hoverStart = nil
            let f = vm.footprint(for: .prompter)
            let zone = NSRect(x: midX - f.width / 2, y: top - f.height, width: f.width, height: f.height)
            let inside = zone.contains(mouse)
            setTickRate(fast: mouse.y > top - f.height - 160)
            if vm.prompter.isHovered != inside { vm.prompter.isHovered = inside }
            if NSEvent.pressedMouseButtons == 0, panel.ignoresMouseEvents == inside {
                panel.ignoresMouseEvents = !inside
            }
            return
        }
        if vm.prompter.isHovered { vm.prompter.isHovered = false }

        // Most of the time the pointer is nowhere near the island: nothing to
        // do, and the check slows down until it comes back near the top.
        if !vm.isExpanded, !vm.isFullScreen, mouse.y < top - 160 || !NSMouseInRect(mouse, screen.frame, false),
           !overBanner, bannerDragStart == nil, hoverStart == nil, !holdHoverUntilLeave, !vm.ui.hoveringBubble {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            setTickRate(fast: false)
            return
        }
        setTickRate(fast: true)
        Diag.count("window.tickNear")

        // Full screen: the island stays tucked away until the pointer touches the
        // top edge (like the hidden menu bar), then drops down; it slides away
        // again shortly after the pointer leaves.
        if vm.isFullScreen && !vm.isExpanded {
            let f = vm.footprint(for: vm.mode)
            if !vm.isRevealed {
                let edge = NSRect(x: midX - f.width / 2 - 20, y: top - 3, width: f.width + 40, height: 5)
                if edge.contains(mouse) && NSEvent.pressedMouseButtons == 0 {
                    vm.isRevealed = true
                    revealedAt = Date()
                    lastInside = Date()
                }
                leaveBanner()
                hoverStart = nil
                return
            }
            let near = NSRect(x: midX - f.width / 2 - 20, y: top - f.height - 20,
                              width: f.width + 40, height: f.height + 22)
            if near.contains(mouse) {
                lastInside = Date()
            } else if Date().timeIntervalSince(lastInside) > 0.6 {
                vm.isRevealed = false
                leaveBanner()
                hoverStart = nil
                return
            }
            // Give it a moment to drop down before hovering can open it, so
            // touching the edge doesn't throw a big panel over your game.
            guard Date().timeIntervalSince(revealedAt) > 0.4 else { return }
        }

        if vm.isExpanded {
            overBanner = false
            if vm.ui.hoveringBubble { vm.ui.hoveringBubble = false }
            let f = vm.footprint(for: .expanded)
            let zone = NSRect(x: midX - f.width / 2 - 12, y: top - f.height - 12,
                              width: f.width + 24, height: f.height + 14)
            let inside = zone.contains(mouse)
            // Clicks only while the pointer is over the panel: the empty,
            // see-through part of Brim's window around it lets them through
            // to whatever is below (a call banner's buttons, a menu). Not
            // switched mid-drag, so a slider keeps following.
            if inside, panel.ignoresMouseEvents {
                // Also mid-drag, so a dragged script can land on the panel.
                panel.ignoresMouseEvents = false
            } else if !inside, !panel.ignoresMouseEvents, NSEvent.pressedMouseButtons == 0 {
                panel.ignoresMouseEvents = true
            }
            if inside {
                lastInside = Date()
            } else if Date().timeIntervalSince(lastInside) > 0.25 {
                setExpanded(false)
            }
        } else {
            let f = vm.footprint(for: vm.mode)
            let left = midX - f.width / 2 + vm.shapeShift(for: vm.mode)
            var right = left + f.width

            // Split: the circle (or a notch's extra wing) is for clicking (it
            // shows the next activity), so it takes clicks and doesn't open
            // the panel. Only the pill does.
            var overBubble = false
            if vm.secondaryMode != nil {
                let h = vm.closedSize.height
                if vm.isIsland {
                    let bubble = NSRect(x: right - h, y: top - vm.topInset - h, width: h, height: h)
                    overBubble = bubble.insetBy(dx: -2, dy: -2).contains(mouse)
                    right -= vm.splitShrink - vm.bubbleGap / 2
                } else {
                    let wingStart = right - vm.radii(for: vm.mode).top - vm.notchExtension
                    let wing = NSRect(x: wingStart, y: top - h, width: vm.notchExtension, height: h)
                    overBubble = wing.insetBy(dx: -2, dy: -2).contains(mouse)
                    right = wingStart
                }
            }
            if vm.ui.hoveringBubble != overBubble { vm.ui.hoveringBubble = overBubble }

            let zone = NSRect(x: left - 6, y: top - f.height - 4,
                              width: right - left + 12, height: f.height + 6)
            let zoneContainsMouse = !overBubble && (vm.secondaryMode == nil
                ? zone.contains(mouse)
                : zone.contains(mouse) && mouse.x < right)
            // Over a banner the panel takes the trackpad, for the swipe up.
            overBanner = vm.mode == .banner && zoneContainsMouse
            let takesEvents = overBubble || overBanner
            if panel.ignoresMouseEvents == takesEvents { panel.ignoresMouseEvents = !takesEvents }

            // A banner was clicked open: keep the panel shut.
            if vm.ui.bannerClicked {
                vm.ui.bannerClicked = false
                holdHoverUntilLeave = true
                bannerDragStart = nil
                hoverStart = nil
            }
            // A file dragged onto the island opens the panel, ready to drop
            // it on the shelf.
            if zoneContainsMouse, !overBanner, NSEvent.pressedMouseButtons & 1 != 0, fileIsBeingDragged() {
                vm.ui.showsMirror = false
                setExpanded(true)
                return
            }
            // Click and drag up on a banner (for a mouse): the same flick.
            if overBanner || bannerDragStart != nil {
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    if bannerDragStart == nil, overBanner { bannerDragStart = mouse.y }
                    // Screen coordinates grow upwards.
                    if let start = bannerDragStart, mouse.y - start > Self.bannerDragThreshold {
                        bannerDragStart = nil
                        dismissBanner()
                        return
                    }
                } else {
                    bannerDragStart = nil
                }
            }

            // Just flicked a banner away: wait until the pointer leaves.
            if holdHoverUntilLeave {
                if !zoneContainsMouse { holdHoverUntilLeave = false }
                hoverStart = nil
                return
            }
            // A banner opens a little later than the pill, leaving time to
            // swipe it away instead.
            let delay = vm.mode == .banner ? 0.3 : 0.08
            // Don't pop open while you're dragging a window across the top.
            if zoneContainsMouse && NSEvent.pressedMouseButtons == 0 {
                if let start = hoverStart {
                    if Date().timeIntervalSince(start) > delay { setExpanded(true) }
                } else {
                    hoverStart = Date()
                }
            } else {
                hoverStart = nil
            }
        }
    }

    private var tickIsFast = false

    /// 30 checks a second while the pointer is near the island (hover must
    /// feel instant), 8 elsewhere: a quarter of the wake-ups, and the pointer
    /// takes longer than an eighth of a second to reach the top anyway.
    private func setTickRate(fast: Bool) {
        guard timer == nil || fast != tickIsFast else { return }
        tickIsFast = fast
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 30.0 : 1.0 / 8.0, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        t.tolerance = fast ? 0.004 : 0.03
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The drag pasteboard's count when Brim last looked: a new drag changes it.
    private var seenDragCount = NSPasteboard(name: .drag).changeCount

    /// A new drag with a file in it is going on.
    private func fileIsBeingDragged() -> Bool {
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != seenDragCount else { return false }
        seenDragCount = board.changeCount
        return board.types?.contains(.fileURL) ?? false
    }

    /// The banner on screen goes away (it stays in the list) and the next
    /// one, if any, comes in.
    private func dismissBanner() {
        overBanner = false
        holdHoverUntilLeave = true
        hoverStart = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { alerts.dismissCurrent() }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func setExpanded(_ expanded: Bool) {
        guard vm.isExpanded != expanded else { return }
        vm.isExpanded = expanded
        // The lock screen copy always lets clicks through; the everyday window
        // only takes them while open.
        activePanel?.ignoresMouseEvents = !expanded
        hoverStart = nil
        lastInside = Date()
        if !expanded {
            // Closing the panel turns the camera off and folds any menu away.
            vm.ui.showsMirror = false
            vm.ui.showsScripts = false
            vm.ui.scriptDropTargeted = false
            vm.ui.shelfDropTargeted = false
            vm.ui.openMenu = nil
        }
        if expanded {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            vm.media.syncNow()
        }
    }
}

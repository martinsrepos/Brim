import AppKit
import Observation
import SwiftUI

/// Puts a window on the lock screen.
///
/// macOS hides every app window while the screen is locked. The exception is a
/// SkyLight "space" at the absolute level Notification Center uses on the lock
/// screen (400). Creating such a space and moving our window into it keeps the
/// notch visible over the lock screen. Same technique as the MIT-licensed
/// SkyLightWindow package by Lakr233, used by MewNotch.
///
/// SkyLight is a private framework, so every symbol is looked up at runtime: if
/// a future macOS removes one, this quietly does nothing instead of crashing.
@MainActor
enum LockScreenSpace {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private struct Space {
        var connection: Int32
        var id: Int32
        var addWindows: AddWindows
    }

    /// kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock
    private static let notificationCenterAtScreenLock: Int32 = 400

    private static let space: Space? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let library = dlopen(path, RTLD_NOW),
              let mainConnection = dlsym(library, "SLSMainConnectionID"),
              let spaceCreate = dlsym(library, "SLSSpaceCreate"),
              let setLevel = dlsym(library, "SLSSpaceSetAbsoluteLevel"),
              let showSpaces = dlsym(library, "SLSShowSpaces"),
              let addWindows = dlsym(library, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            appLog.error("SkyLight symbols unavailable; lock screen display disabled")
            return nil
        }
        let connection = unsafeBitCast(mainConnection, to: MainConnectionID.self)()
        let id = unsafeBitCast(spaceCreate, to: SpaceCreate.self)(connection, 1, 0)
        _ = unsafeBitCast(setLevel, to: SpaceSetAbsoluteLevel.self)(connection, id, notificationCenterAtScreenLock)
        _ = unsafeBitCast(showSpaces, to: ShowSpaces.self)(connection, [id] as CFArray)
        return Space(connection: connection, id: id,
                     addWindows: unsafeBitCast(addWindows, to: AddWindows.self))
    }()

    /// Moves the window into the lock-screen-level space. Returns false if unsupported.
    @discardableResult
    static func add(_ window: NSWindow) -> Bool {
        guard let space else { return false }
        window.canBecomeVisibleWithoutLogin = true
        _ = space.addWindows(space.connection, space.id, [window.windowNumber] as CFArray, 7)
        return true
    }
}

/// Tracks whether the screen is locked. macOS broadcasts lock and unlock as
/// distributed notifications, which is public and needs no permission.
@MainActor
@Observable
final class LockMonitor {
    enum State: Equatable {
        case unlocked
        case locked
        /// Just unlocked: the lock is shown opening for a moment, like on iPhone.
        case unlocking
    }

    private(set) var state: State
    /// While unlocking: false = the closed lock, true = it has opened.
    private(set) var isOpen = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// Told when the screen locks and once it's fully unlocked.
    @ObservationIgnored var onChange: (@MainActor (State) -> Void)?

    init() {
        state = Self.sessionIsLocked ? .locked : .unlocked
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didLock() }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didUnlock() }
        })
    }

    private func didLock() {
        settleTask?.cancel()
        isOpen = false
        state = .locked
        onChange?(.locked)
    }

    private func didUnlock() {
        guard state == .locked else { return }
        // 1. Once the lock screen has gone, the glass fades in (onChange)
        //    as the lock opens.
        // 2. The open lock fades and the island's content appears.
        isOpen = false
        state = .unlocking
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            // The unlock is announced a moment before the lock screen has
            // finished sliding away; the fade waits for it.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange?(.unlocking)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self?.isOpen = true }
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            self?.state = .unlocked
            self?.isOpen = false
            self?.onChange?(.unlocked)
        }
    }

    /// Covers the case where Brim launches while the screen is already locked.
    private static var sessionIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

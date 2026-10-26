import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox
import Observation

/// The four looks a level icon steps through (keyboard backlight and volume):
/// off, low, middle (from halfway up) and the top.
enum LevelTier: Equatable {
    case off, low, middle, maximum
}

// MARK: - Volume

/// The output volume of the current speakers or headphones.
struct VolumeReading: Equatable {
    /// 0...1, as macOS reports it.
    var volume: Double
    var muted: Bool
    /// "MacBook Pro Speakers", "AirPods Pro", "LG UltraFine"...
    var device: String

    var isOff: Bool { muted || volume < 0.005 }
    var fraction: Double { isOff ? 0 : volume }

    var tier: LevelTier {
        if isOff { return .off }
        if volume >= 0.995 { return .maximum }
        if volume >= 0.5 { return .middle }
        return .low
    }

    /// Lit waves in the icon: none when off, then one, two, three.
    var waves: Int {
        switch tier {
        case .off: return 0
        case .low: return 1
        case .middle: return 2
        case .maximum: return 3
        }
    }

    /// For places that show a plain symbol (the banner itself draws
    /// VolumeSymbol).
    var symbol: String { muted ? "speaker.slash.fill" : "speaker.wave.3.fill" }

    /// The bar shows how loud; the text only says where the sound goes, or
    /// that it's muted.
    var label: String { muted ? "Muted" : device }

    /// Small wobbles (a few thousandths) aren't a change.
    func differs(from other: VolumeReading) -> Bool {
        abs(volume - other.volume) >= 0.001 || muted != other.muted
    }
}

extension NotchAlert {
    /// The volume banner. Live like the backlight one: it updates in place
    /// while you keep pressing the keys or dragging the slider.
    static func volumeBanner(_ reading: VolumeReading) -> NotchAlert {
        NotchAlert(symbol: reading.symbol, tint: reading.isOff ? .gray : .white,
                   title: "Volume", subtitle: reading.label,
                   duration: 2, volume: reading, liveKey: "volume")
    }

    /// How full a level banner's bar is (backlight or volume), nil for others.
    var levelFraction: Double? {
        backlight?.fraction ?? volume?.fraction ?? brightness
    }
}

/// Follows the volume and mute of the default output, whoever changes it:
/// the volume keys (any keyboard), the menu bar, Control Center, AirPods.
/// Switching to other speakers or headphones shows no banner; changing
/// their volume does. Needs no permission.
@MainActor
@Observable
final class VolumeMonitor {
    private(set) var reading: VolumeReading?

    /// A change: show the banner.
    @ObservationIgnored var onChange: (@MainActor (VolumeReading) -> Void)?

    @ObservationIgnored private var audio: DefaultDeviceWatcher?

    func start() {
        let audio = self.audio ?? DefaultDeviceWatcher(scope: kAudioDevicePropertyScopeOutput,
                                                       defaultSelector: kAudioHardwarePropertyDefaultOutputDevice)
        self.audio = audio
        audio.start(
            onDevice: { [weak self] id in self?.reading = Self.read(id) },   // new output: the starting point
            onChange: { [weak self] id in self?.changed(id) })
    }

    func stop() {
        audio?.stop()
        reading = nil
    }

    private func changed(_ id: AudioObjectID) {
        guard let new = Self.read(id) else { return }
        guard let previous = reading else { reading = new; return }
        guard new.differs(from: previous) else { return }
        reading = new
        Diag.count("volume.change")
        onChange?(new)
    }

    /// nil for outputs whose volume can't be read (many HDMI and DisplayPort
    /// monitors): those set their volume on the monitor itself.
    private static func read(_ id: AudioObjectID) -> VolumeReading? {
        let scope = kAudioDevicePropertyScopeOutput
        guard let volume = CoreAudioProperty.volume(id, scope: scope) else { return nil }
        return VolumeReading(volume: Double(min(max(volume, 0), 1)),
                             muted: CoreAudioProperty.isMuted(id, scope: scope) ?? false,
                             device: CoreAudioProperty.name(id) ?? "Output")
    }
}

// MARK: - Microphone

/// The Mac's microphone, on or muted.
struct MicrophoneReading: Equatable {
    var muted: Bool
    var device: String
}

extension NotchAlert {
    static func microphoneBanner(_ reading: MicrophoneReading) -> NotchAlert {
        NotchAlert(symbol: reading.muted ? "mic.slash.fill" : "mic.fill",
                   tint: reading.muted ? .gray : .white,
                   title: "Microphone", subtitle: reading.muted ? "Muted" : "On",
                   duration: 2, liveKey: "microphone")
    }
}

/// Follows whether the default microphone is muted, whoever mutes it: the
/// keyboard's Mute Microphone key through Logi Options+, Control Center,
/// Brim's own call button. Muted means its mute switch is on or its input
/// level is at zero (some tools mute that way, and so does Brim for
/// microphones without a switch). Mute buttons inside apps (Zoom, FaceTime)
/// only mute the call, not the microphone, so they don't show here.
@MainActor
@Observable
final class MicrophoneMonitor {
    private(set) var reading: MicrophoneReading?

    @ObservationIgnored var onChange: (@MainActor (MicrophoneReading) -> Void)?

    @ObservationIgnored private var audio: DefaultDeviceWatcher?

    func start() {
        let audio = self.audio ?? DefaultDeviceWatcher(scope: kAudioDevicePropertyScopeInput,
                                                       defaultSelector: kAudioHardwarePropertyDefaultInputDevice)
        self.audio = audio
        audio.start(
            onDevice: { [weak self] id in self?.reading = Self.read(id) },
            onChange: { [weak self] id in self?.changed(id) })
    }

    func stop() {
        audio?.stop()
        reading = nil
    }

    private func changed(_ id: AudioObjectID) {
        guard let new = Self.read(id) else { return }
        guard let previous = reading else { reading = new; return }
        // Only muting and unmuting: the input level moving isn't news.
        guard new.muted != previous.muted else { return }
        reading = new
        Diag.count("microphone.change")
        onChange?(new)
    }

    private static func read(_ id: AudioObjectID) -> MicrophoneReading? {
        let scope = kAudioDevicePropertyScopeInput
        let switchedOff = CoreAudioProperty.isMuted(id, scope: scope)
        let level = CoreAudioProperty.volume(id, scope: scope)
        guard switchedOff != nil || level != nil else { return nil }
        let muted = (switchedOff ?? false) || (level.map { $0 < 0.005 } ?? false)
        return MicrophoneReading(muted: muted, device: CoreAudioProperty.name(id) ?? "Microphone")
    }
}

// MARK: - Core Audio

/// Listens to whichever device is the default output (or input), and to its
/// volume and mute. Follows the default as it changes.
@MainActor
private final class DefaultDeviceWatcher {
    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let scope: AudioObjectPropertyScope
    private let defaultSelector: AudioObjectPropertySelector
    private var device = AudioObjectID(0)
    private var defaultListener: Listener?
    private var deviceListeners: [Listener] = []
    private var onDevice: ((AudioObjectID) -> Void)?
    private var onChange: ((AudioObjectID) -> Void)?

    init(scope: AudioObjectPropertyScope, defaultSelector: AudioObjectPropertySelector) {
        self.scope = scope
        self.defaultSelector = defaultSelector
    }

    func start(onDevice: @escaping (AudioObjectID) -> Void, onChange: @escaping (AudioObjectID) -> Void) {
        guard defaultListener == nil else { return }
        self.onDevice = onDevice
        self.onChange = onChange
        defaultListener = listen(AudioObjectID(kAudioObjectSystemObject),
                                 CoreAudioProperty.address(defaultSelector, scope: kAudioObjectPropertyScopeGlobal)) { [weak self] in
            self?.followDefault()
        }
        followDefault()
    }

    func stop() {
        if let defaultListener { remove(defaultListener) }
        defaultListener = nil
        deviceListeners.forEach(remove)
        deviceListeners.removeAll()
        device = 0
    }

    private func followDefault() {
        guard let id = CoreAudioProperty.defaultDevice(defaultSelector), id != device else { return }
        deviceListeners.forEach(remove)
        deviceListeners.removeAll()
        device = id
        onDevice?(id)
        // Some devices have one main volume, some only one per channel, and
        // macOS's "virtual main volume" covers both. Listening to all of them
        // means every device reports; the monitors drop the repeats.
        var addresses = [CoreAudioProperty.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)]
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            addresses.append(CoreAudioProperty.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element))
            addresses.append(CoreAudioProperty.address(kAudioDevicePropertyMute, scope: scope, element: element))
        }
        deviceListeners = addresses.compactMap { address in
            listen(id, address) { [weak self] in
                guard let self, self.device == id else { return }
                self.onChange?(id)
            }
        }
    }

    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                        _ action: @escaping @MainActor () -> Void) -> Listener? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { action() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
    }
}

/// Reading Core Audio properties.
private enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var where_ = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &device) == 0,
              device != 0 else { return nil }
        return device
    }

    /// The device's overall level: its virtual main volume, else its main
    /// volume, else its first channel's.
    static func volume(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Float32? {
        float(id, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope))
            ?? float(id, address(kAudioDevicePropertyVolumeScalar, scope: scope))
            ?? float(id, address(kAudioDevicePropertyVolumeScalar, scope: scope, element: 1))
    }

    static func isMuted(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool? {
        (uint(id, address(kAudioDevicePropertyMute, scope: scope))
            ?? uint(id, address(kAudioDevicePropertyMute, scope: scope, element: 1))).map { $0 != 0 }
    }

    static func name(_ id: AudioObjectID) -> String? {
        var where_ = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &where_, 0, nil, &size, pointer)
        }
        guard status == 0, let value else { return nil }
        let name = value.takeRetainedValue() as String
        return name.isEmpty ? nil : name
    }

    private static func float(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == 0 else { return nil }
        return value
    }

    private static func uint(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == 0 else { return nil }
        return value
    }
}

// MARK: - Volume icon

/// The volume banner's icon, from Apple's SF Symbols. The speaker never
/// moves: underneath is the speaker with all three waves greyed out, and on
/// top the lit waves fade in one by one as the volume goes up (and out as it
/// goes down). The lit layers are the one-, two- and three-wave symbols,
/// lined up on the speaker, so each step adds exactly one wave.
/// Muted, the slashed speaker crossfades in.
struct VolumeSymbol: View {
    let reading: VolumeReading

    var body: some View {
        ZStack {
            if reading.muted {
                Image(systemName: "speaker.slash.fill")
                    .transition(.opacity)
            } else {
                ZStack(alignment: .leading) {
                    // Variable value 0: the speaker solid, its waves dimmed.
                    Image(systemName: "speaker.wave.3.fill", variableValue: 0)
                    ForEach(1...3, id: \.self) { count in
                        Image(systemName: "speaker.wave.\(count).fill")
                            .opacity(reading.waves >= count ? 1 : 0)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: reading.waves)
        .animation(.easeInOut(duration: 0.2), value: reading.muted)
    }
}

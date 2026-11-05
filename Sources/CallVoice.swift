import AVFoundation
import SwiftUI

/// How loud your microphone is during a call, so the call's waveform moves
/// with your voice. Only the loudness is measured, twenty times a second, and
/// only while a call is showing: nothing is recorded, kept or sent, and no
/// speech is recognised. Uses the Microphone permission the teleprompter
/// already asks for; without it, the waveform falls back to a gentle,
/// voice-free animation.
@MainActor @Observable
final class CallVoiceMeter {
    /// The last few readings, 0...1, newest last.
    private(set) var levels: [Double] = Array(repeating: 0, count: 5)
    /// Measuring right now (the permission is there and the mic started).
    private(set) var isListening = false

    @ObservationIgnored private var users = 0
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored private let box = LevelBox()
    @ObservationIgnored private var smoothed = 0.0

    /// A view showing the call appeared: start measuring with the first one.
    func attach() {
        users += 1
        if users == 1 { start() }
    }

    /// A view showing the call went away: stop with the last one.
    func detach() {
        users = max(0, users - 1)
        if users == 0 { stop() }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard granted, let self, self.users > 0 else { return }
                        self.run()
                    }
                }
            }
        default:
            break
        }
    }

    private func run() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        guard Self.tap(engine, into: box) else { return }
        self.engine = engine
        isListening = true
        // Readings move along twenty times a second, newest last.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Another microphone chosen (AirPods taking over, say): start again on it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                if !Self.tap(engine, into: self.box) { self.stop() }
            }
        }
        Diag.event("Call waveform: following the microphone")
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isListening = false
        smoothed = 0
        levels = Array(repeating: 0, count: levels.count)
    }

    /// Rises quickly when you speak, settles a little more slowly, like a
    /// level meter.
    private func tick() {
        let target = box.take()
        smoothed = target > smoothed ? smoothed + (target - smoothed) * 0.6 : smoothed + (target - smoothed) * 0.25
        levels.removeFirst()
        levels.append(smoothed)
    }

    /// Listens to the default microphone, keeping only the loudest moment of
    /// each slice of sound.
    private static func tap(_ engine: AVAudioEngine, into box: LevelBox) -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.offer(loudness(of: buffer))
        }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
    }

    /// Speech-range loudness, 0...1: -50 dB (a quiet room) to -12 dB (talking
    /// close to the mic).
    nonisolated private static func loudness(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(Double(rms))
        return min(max((decibels + 50) / 38, 0), 1)
    }
}

/// The loudest reading since the last look, shared between the audio thread
/// and the main thread.
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0

    func offer(_ level: Double) {
        lock.lock()
        peak = max(peak, level)
        lock.unlock()
    }

    func take() -> Double {
        lock.lock()
        defer { peak = 0; lock.unlock() }
        return peak
    }
}

/// The call's waveform: five bars that move with your voice, the middle one
/// first and the outer ones a moment later, like a ripple. Without the
/// microphone (or in Brim Demo) it's the gentle animation the music uses.
struct CallVoiceWave: View {
    let meter: CallVoiceMeter
    var live = true
    var color: Color = .green

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Outer bars a little shorter, so it reads as a voice, not a meter.
    private static let reach: [Double] = [0.6, 0.85, 1, 0.85, 0.6]
    /// Which reading each bar shows: the newest in the middle.
    private static let age: [Int] = [2, 3, 4, 3, 2]

    var body: some View {
        if live && meter.isListening {
            GeometryReader { proxy in
                let barWidth = max(1.5, proxy.size.width / 9)
                HStack(alignment: .center, spacing: barWidth) {
                    ForEach(0..<5, id: \.self) { i in
                        let level = meter.levels[Self.age[i]] * Self.reach[i]
                        Capsule()
                            .fill(color)
                            .frame(width: barWidth,
                                   height: max(barWidth, proxy.size.height * (0.18 + 0.82 * level)))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: meter.levels)
            }
            .accessibilityHidden(true)
        } else {
            EqualizerView(color: color, isPlaying: true)
        }
    }
}

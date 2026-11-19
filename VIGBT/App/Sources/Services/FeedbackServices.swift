import AVFoundation
import CoreHaptics
import UIKit
import VIGBTCore

// MARK: - Speech

/// Spoken announcements. Uses VoiceOver's own voice when it is running (respecting the user's
/// rate and voice settings), otherwise a speech synthesizer.
@MainActor
final class SpeechService {
    private let synthesizer = AVSpeechSynthesizer()

    func say(_ text: String, interrupt: Bool = false) {
        if UIAccessibility.isVoiceOverRunning {
            let s = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: !interrupt])
            UIAccessibility.post(notification: .announcement, argument: s)
            return
        }
        if interrupt { synthesizer.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(u)
    }
}

// MARK: - Audio session

enum AudioSessionMode {
    /// Strike detection: microphone on, no AGC.
    case capture
    /// Walking and homing: playback that keeps going with the screen locked and ducks other audio.
    case guidance

    func apply() {
        let s = AVAudioSession.sharedInstance()
        do {
            switch self {
            case .capture:
                try s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            case .guidance:
                try s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
            try s.setActive(true)
        } catch {
            // Non-fatal: audio still plays with the previous configuration.
        }
    }
}

// MARK: - Spatial audio beacon (Phase 3.2)

/// A virtual sonar beacon rendered with `AVAudioEnvironmentNode`. Its position is listener-relative
/// (already corrected for the user's heading by `NavigationEngine`), so the listener stays fixed.
@MainActor
final class AudioBeaconService {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var interval: Double = 1.0
    private var cents: Double = 0
    private var generation = 0
    private(set) var isRunning = false

    init() {
        engine.attach(player)
        engine.attach(environment)
        // 3D sources must be mono into the environment node.
        engine.connect(player, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.distanceAttenuationParameters.rolloffFactor = 0.3
        player.renderingAlgorithm = .HRTFHQ
        player.sourceMode = .pointSource
    }

    func start() {
        guard !isRunning else { return }
        do {
            try engine.start()
        } catch {
            return
        }
        player.play()
        isRunning = true
        generation += 1
        schedulePulse(generation)
    }

    func stop() {
        generation += 1
        player.stop()
        engine.stop()
        isRunning = false
    }

    func update(_ g: NavigationGuidance) {
        // AVAudio3D: +x right, +y up, −z forward.
        player.position = AVAudio3DPoint(x: Float(g.beaconRight), y: 0, z: Float(-g.beaconForward))
        interval = g.pulseIntervalSeconds
        cents = g.pitchShiftCents
    }

    private func schedulePulse(_ gen: Int) {
        guard gen == generation else { return }
        player.scheduleBuffer(buffer(cents: Int(cents)), completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.schedulePulse(gen)
        }
    }

    /// 80 ms sine ping (880 Hz, shifted by `cents`) with a fast exponential decay.
    private func buffer(cents: Int) -> AVAudioPCMBuffer {
        if let b = buffers[cents] { return b }
        let frames = AVAudioFrameCount(format.sampleRate * 0.08)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        let f = 880 * pow(2, Double(cents) / 1200)
        let data = b.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            let attack = min(1, t / 0.004)
            data[i] = Float(0.8 * attack * exp(-t / 0.025) * sin(2 * .pi * f * t))
        }
        buffers[cents] = b
        return b
    }

    /// Short confirmation chime for "ball found".
    func playSuccessChime() {
        if !isRunning { start() }
        player.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        for c in [0, 400, 700] { player.scheduleBuffer(buffer(cents: c), completionHandler: nil) }
    }
}

// MARK: - Haptics (Phase 4.3)

@MainActor
final class HapticsService {
    private var engine: CHHapticEngine?
    private var tickInterval: Double = 0.6
    private var tickIntensity: Float = 0.5
    private var ticking = false
    private var generation = 0
    private let notifier = UINotificationFeedbackGenerator()

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.resetHandler = { [weak self] in
            Task { @MainActor in try? self?.engine?.start() }
        }
        try? engine?.start()
    }

    func handle(_ event: HomingEvent) {
        switch event {
        case .peripheralDetected:
            play([transient(at: 0, intensity: 0.6, sharpness: 0.4), transient(at: 0.12, intensity: 0.6, sharpness: 0.4)])
        case let .tick(interval, intensity):
            tickInterval = interval
            tickIntensity = Float(intensity)
            if !ticking {
                ticking = true
                generation += 1
                tick(generation)
            }
        case .lost:
            stopTicking()
            notifier.notificationOccurred(.warning)
        case .locked:
            stopTicking()
            notifier.notificationOccurred(.success)
        }
    }

    func stopTicking() {
        ticking = false
        generation += 1
    }

    /// Single confirmation pulse (calibration locked, shot captured).
    func confirm() {
        notifier.notificationOccurred(.success)
    }

    /// Distinct from the success tap: used when the ball is predicted to land in water.
    func warn() {
        notifier.notificationOccurred(.warning)
    }

    private func tick(_ gen: Int) {
        guard ticking, gen == generation else { return }
        play([transient(at: 0, intensity: tickIntensity, sharpness: 0.9)])
        DispatchQueue.main.asyncAfter(deadline: .now() + tickInterval) { [weak self] in
            self?.tick(gen)
        }
    }

    private func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: time)
    }

    private func play(_ events: [CHHapticEvent]) {
        guard let engine, let pattern = try? CHHapticPattern(events: events, parameters: []),
              let player = try? engine.makePlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }
}

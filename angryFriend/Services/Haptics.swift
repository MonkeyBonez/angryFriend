import UIKit
import CoreHaptics

/// Every buzz in the app goes through here so the feel stays consistent and the
/// generators are warmed up before the moment that needs them — an un-prepared
/// generator can drop the first hit, which is exactly the tap you don't want to miss.
///
/// Sharp one-off feedback uses UIKit's tuned generators. The explosion uses Core
/// Haptics, because a decaying rumble under a sharp crack is a pattern UIKit's
/// fixed styles simply can't express — with a UIKit fallback for devices without
/// a Taptic Engine that supports CHHapticEngine.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notice = UINotificationFeedbackGenerator()

    /// Call before a screen where taps are about to happen.
    static func warmUp() {
        light.prepare()
        medium.prepare()
        heavy.prepare()
        rigid.prepare()
        selection.prepare()
        notice.prepare()
        HapticEngine.shared.start()
    }

    /// Peeling a sticker off the sheet — friend taps, card taps.
    static func peel() {
        light.impactOccurred(intensity: 0.8)
        light.prepare()
    }

    /// Pressing a chunky button down into its shadow.
    static func press() {
        medium.impactOccurred()
        medium.prepare()
    }

    /// Flicking between segmented options.
    static func flick() {
        selection.selectionChanged()
        selection.prepare()
    }

    /// A card came back safe — crisp and clean, over fast.
    static func safe() {
        rigid.impactOccurred(intensity: 0.7)
        rigid.prepare()
    }

    /// Something finished successfully in the background.
    static func done() {
        notice.notificationOccurred(.success)
        notice.prepare()
    }

    static func warn() {
        notice.notificationOccurred(.warning)
        notice.prepare()
    }

    /// The angry card: a hard crack followed by a rumble that decays over ~0.7s.
    static func boom() {
        if HapticEngine.shared.playBoom() { return }

        notice.notificationOccurred(.error)
        let beats: [(delay: Duration, intensity: CGFloat)] = [
            (.milliseconds(0), 1.00), (.milliseconds(70), 0.85), (.milliseconds(150), 1.00),
            (.milliseconds(250), 0.60), (.milliseconds(340), 0.80), (.milliseconds(460), 0.45),
        ]
        for beat in beats {
            Task { @MainActor in
                try? await Task.sleep(for: beat.delay)
                heavy.impactOccurred(intensity: beat.intensity)
            }
        }
    }

    /// Confetti landing on the result screen — light, scattered, celebratory.
    static func sprinkle() {
        for step in 0..<4 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(step * 95))
                light.impactOccurred(intensity: 0.5)
            }
        }
    }

    /// A steady tick while cards are being cut out, so the wait has a pulse.
    static func tick() {
        light.impactOccurred(intensity: 0.35)
    }
}

// MARK: - Core Haptics

/// Wraps a single long-lived `CHHapticEngine`. Creating an engine per playback is
/// slow enough to miss the moment, and the engine stops itself when the app
/// backgrounds — so it's restarted lazily and on the reset handler.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    private var engine: CHHapticEngine?
    private var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    private init() {}

    func start() {
        guard isSupported, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            engine.stoppedHandler = { _ in }
            try engine.start()
            self.engine = engine
        } catch {
            engine = nil
        }
    }

    /// Returns false if Core Haptics is unavailable so the caller can fall back.
    func playBoom() -> Bool {
        guard isSupported else { return false }
        start()
        guard let engine else { return false }

        // A sharp crack, a second slap on the rebound, then a low rumble that
        // fades — the shape of something breaking rather than a plain error buzz.
        let crack = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
            ],
            relativeTime: 0
        )
        let rebound = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
            ],
            relativeTime: 0.11
        )
        let rumble = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.75),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15),
            ],
            relativeTime: 0.04,
            duration: 0.66
        )
        let decay = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 1.0),
                .init(relativeTime: 0.22, value: 0.7),
                .init(relativeTime: 0.66, value: 0.0),
            ],
            relativeTime: 0.04
        )

        do {
            let pattern = try CHHapticPattern(events: [crack, rebound, rumble], parameterCurves: [decay])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }
}

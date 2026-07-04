import Foundation

#if os(iOS) || os(tvOS)
import AVFAudio

/// Owns the `AVAudioSession` for music playback: category/activation plus
/// interruption and route-change handling (the two things that make an audio
/// app behave correctly on a phone). Callbacks are delivered on the main actor
/// so the engine can react without extra hops.
///
/// - Interruptions (a phone call, Siri): pause on begin; resume on end when the
///   system says we should.
/// - Route changes: pause when the old output device becomes unavailable — i.e.
///   headphones were unplugged — matching iOS's system-audio conventions.
@MainActor
public final class AudioSessionController {
    public var onInterruptionBegan: (() -> Void)?
    public var onInterruptionEnded: (_ shouldResume: Bool) -> Void = { _ in }
    public var onOldDeviceUnavailable: (() -> Void)?

    private var observersInstalled = false

    public init() {}

    /// Configure the shared session for background-capable music playback.
    public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setActive(true)
        installObservers()
    }

    public func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            var shouldResume = false
            if let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            }
            onInterruptionEnded(shouldResume)
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard
            let info = note.userInfo,
            let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }
        if reason == .oldDeviceUnavailable {
            onOldDeviceUnavailable?()
        }
    }
}

#else

/// Non-iOS stub so the engine compiles on macOS for host-side unit testing.
@MainActor
public final class AudioSessionController {
    public var onInterruptionBegan: (() -> Void)?
    public var onInterruptionEnded: (_ shouldResume: Bool) -> Void = { _ in }
    public var onOldDeviceUnavailable: (() -> Void)?
    public init() {}
    public func activate() throws {}
    public func deactivate() {}
}

#endif

import Foundation
#if canImport(AppIntents)
import AppIntents
#endif

/// Process-wide hooks the app registers at launch so widget / Control-Center
/// `AppIntent`s can drive playback. The intents below conform to
/// `AudioPlaybackIntent`, which makes the system run `perform()` in the *app*
/// process (where the audio session and `PlaybackEngine` live) rather than the
/// widget extension sandbox — so these closures are set from the running app.
@MainActor
public enum PlaybackRemoteControl {
    public static var togglePlayPause: (() -> Void)?
    public static var next: (() -> Void)?
    public static var previous: (() -> Void)?
}

#if canImport(AppIntents)
/// Interactive widget button: toggle play/pause without leaving the Home Screen.
@available(iOS 17.0, macOS 14.0, *)
public struct TogglePlayPauseIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play or Pause"
    public init() {}
    public func perform() async throws -> some IntentResult {
        await MainActor.run { PlaybackRemoteControl.togglePlayPause?() }
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, *)
public struct NextTrackIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Next Track"
    public init() {}
    public func perform() async throws -> some IntentResult {
        await MainActor.run { PlaybackRemoteControl.next?() }
        return .result()
    }
}
#endif

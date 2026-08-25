namespace Mozz.Desktop.Audio.Platform;

/// <summary>Metadata for the OS "now playing" surface.</summary>
public sealed record NowPlayingMetadata(
    string Title,
    string Artist,
    string? Album,
    TimeSpan Duration);

/// <summary>
/// The OS-level "now playing" integration: Windows SMTC (so the media keys and
/// the volume-flyout card work) and macOS <c>MPNowPlayingInfoCenter</c>. The app
/// talks to this interface; the concrete surface is chosen per platform and a
/// missing one is a no-op, never a crash. The command events let hardware media
/// keys drive the same transport the buttons do.
/// </summary>
public interface INowPlayingIntegration : IDisposable
{
    void UpdateMetadata(NowPlayingMetadata metadata);
    void UpdateState(PlaybackState state);
    void UpdatePosition(TimeSpan position, TimeSpan duration);

    event EventHandler? PlayPauseRequested;
    event EventHandler? NextRequested;
    event EventHandler? PreviousRequested;
    event EventHandler? StopRequested;
}

/// <summary>
/// Chooses the platform integration, and falls back to the no-op whenever the
/// platform one cannot establish itself.
///
/// macOS is implemented (MPNowPlayingInfoCenter, for the Control Center card).
/// Windows SMTC is not: it needs WinRT interop and can only be verified on a
/// Windows machine. The seam is wired through the view model either way, so
/// filling SMTC in touches this file and nothing else.
///
/// Note the fallback is on <c>IsAvailable</c> rather than on a try/catch here.
/// The macOS surface looks classes and selectors up by name at runtime, so
/// "MediaPlayer.framework did not answer" is an ordinary outcome rather than an
/// exception, and a music player must not care.
/// </summary>
public static class NowPlayingIntegration
{
    public static INowPlayingIntegration Create()
    {
        // if (OperatingSystem.IsWindows()) return new WindowsSmtcIntegration();
        if (OperatingSystem.IsMacOS())
        {
            var mac = new MacNowPlayingIntegration();
            if (mac.IsAvailable) return mac;
            mac.Dispose();
        }
        return new NoopNowPlayingIntegration();
    }
}

/// <summary>The default surface: accepts every update and does nothing, so the rest of the app is platform-blind.</summary>
public sealed class NoopNowPlayingIntegration : INowPlayingIntegration
{
    public void UpdateMetadata(NowPlayingMetadata metadata) { }
    public void UpdateState(PlaybackState state) { }
    public void UpdatePosition(TimeSpan position, TimeSpan duration) { }

    public event EventHandler? PlayPauseRequested { add { } remove { } }
    public event EventHandler? NextRequested { add { } remove { } }
    public event EventHandler? PreviousRequested { add { } remove { } }
    public event EventHandler? StopRequested { add { } remove { } }

    public void Dispose() { }
}

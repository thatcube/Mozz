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
/// Chooses the platform integration. Today every platform gets the no-op: the
/// Windows SMTC and macOS MPNowPlayingInfoCenter surfaces are the one deliberately
/// unfinished piece (they need WinRT and Objective-C runtime interop respectively,
/// and SMTC in particular can only be verified on Windows). The seam is here and
/// wired through the view model, so filling it in is a self-contained change that
/// touches no playback code. See <c>Audio/README.md</c>.
/// </summary>
public static class NowPlayingIntegration
{
    public static INowPlayingIntegration Create()
    {
        // if (OperatingSystem.IsWindows()) return new WindowsSmtcIntegration();
        // if (OperatingSystem.IsMacOS())   return new MacNowPlayingIntegration();
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

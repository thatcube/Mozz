using Mozz.Desktop.Audio;
using Mozz.Desktop.Audio.Platform;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The macOS now-playing surface, against the real MediaPlayer.framework.
///
/// This is Objective-C runtime interop — classes and selectors looked up by
/// name, messages sent through <c>objc_msgSend</c> — and every call in it either
/// returns void or returns an object nobody inspects. That means a completely
/// broken implementation looks exactly like a working one from the outside,
/// which is why <c>DebugReadTitle</c> exists and why these read the record back
/// out of the info centre rather than merely calling the setters.
///
/// Skipped off macOS rather than failed: the class under test is the platform
/// surface, and its absence elsewhere is the design.
/// </summary>
[SupportedOSPlatform("macos")]
public class MacNowPlayingTests
{
    private static bool OnMac => OperatingSystem.IsMacOS();

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct ObjcBlockLiteral
    {
        public nint Isa;
        public int Flags;
        public int Reserved;
        public delegate* unmanaged<nint, nint, nint> Invoke;
        public nint Descriptor;
    }

    [Fact]
    public void TheFrameworkResolves()
    {
        if (!OnMac) return;
        using var np = new MacNowPlayingIntegration();
        Assert.True(np.IsAvailable,
            "MediaPlayer.framework, MPNowPlayingInfoCenter or its property keys did not resolve");
    }

    [Fact]
    public void MetadataReachesTheInfoCentre()
    {
        if (!OnMac) return;
        using var np = new MacNowPlayingIntegration();
        if (!np.IsAvailable) return;

        np.UpdateMetadata(new NowPlayingMetadata(
            "Analog Bloom", "Sol Nakamura", "Analog Bloom", TimeSpan.FromSeconds(214)));
        np.UpdateState(PlaybackState.Playing);

        Assert.Equal("Analog Bloom", np.DebugReadTitle());
    }

    /// Track titles are not ASCII, and NSString-from-UTF-8 is exactly where this
    /// kind of interop goes wrong — silently, with a mangled card as the only
    /// symptom.
    [Theory]
    [InlineData("Ünïcøde ♪ 音楽")]
    [InlineData("Björk — Jóga")]
    [InlineData("🎵 emoji title")]
    public void UnicodeSurvivesTheBridge(string title)
    {
        if (!OnMac) return;
        using var np = new MacNowPlayingIntegration();
        if (!np.IsAvailable) return;

        np.UpdateMetadata(new NowPlayingMetadata(title, "Artist", null, TimeSpan.FromSeconds(60)));
        Assert.Equal(title, np.DebugReadTitle());
    }

    /// A position update rebuilds the whole record, so a mistake there would
    /// blank the card a second after every track starts.
    [Fact]
    public void APositionUpdateKeepsTheMetadata()
    {
        if (!OnMac) return;
        using var np = new MacNowPlayingIntegration();
        if (!np.IsAvailable) return;

        np.UpdateMetadata(new NowPlayingMetadata("Keep Me", "A", "B", TimeSpan.FromSeconds(60)));
        np.UpdatePosition(TimeSpan.FromSeconds(42), TimeSpan.FromSeconds(60));

        Assert.Equal("Keep Me", np.DebugReadTitle());
    }

    /// A position update before any metadata must not publish a half-empty
    /// record — the view model's timer ticks whether or not a track is loaded.
    [Fact]
    public void APositionUpdateWithNoTrackPublishesNothing()
    {
        if (!OnMac) return;
        using var np = new MacNowPlayingIntegration();
        if (!np.IsAvailable) return;

        np.Dispose();                    // clear anything a previous test left
        np.UpdatePosition(TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(60));
        Assert.Null(np.DebugReadTitle());
    }

    /// An album is optional — singles and many self-hosted rips have none — and
    /// a null must be omitted rather than sent as a null object, which throws.
    [Fact]
    public void AMissingAlbumIsOmittedNotSentAsNull()
    {
        if (!OnMac) return;
        using var np = new MacNowPlayingIntegration();
        if (!np.IsAvailable) return;

        np.UpdateMetadata(new NowPlayingMetadata("No Album", "A", null, TimeSpan.FromSeconds(30)));
        Assert.Equal("No Album", np.DebugReadTitle());
    }

    [Fact]
    public void TheFactoryPicksThePlatformSurfaceOnMac()
    {
        using var chosen = NowPlayingIntegration.Create();
        if (OnMac) Assert.IsType<MacNowPlayingIntegration>(chosen);
        else Assert.IsType<NoopNowPlayingIntegration>(chosen);
    }

    [Fact]
    public unsafe void RemoteCommandBlocksRaiseTransportEvents()
    {
        if (!OperatingSystem.IsMacOS()) return;
        using var np = new MacNowPlayingIntegration();
        if (!np.IsAvailable) return;

        AssertBlockRaises(np.DebugTogglePlayPauseBlock,
            handler => np.PlayPauseRequested += handler,
            handler => np.PlayPauseRequested -= handler);
        AssertBlockRaises(np.DebugPlayBlock,
            handler => np.PlayPauseRequested += handler,
            handler => np.PlayPauseRequested -= handler);
        AssertBlockRaises(np.DebugPauseBlock,
            handler => np.PlayPauseRequested += handler,
            handler => np.PlayPauseRequested -= handler);
        AssertBlockRaises(np.DebugNextBlock,
            handler => np.NextRequested += handler,
            handler => np.NextRequested -= handler);
        AssertBlockRaises(np.DebugPreviousBlock,
            handler => np.PreviousRequested += handler,
            handler => np.PreviousRequested -= handler);
        AssertBlockRaises(np.DebugStopBlock,
            handler => np.StopRequested += handler,
            handler => np.StopRequested -= handler);
    }

    private static unsafe void AssertBlockRaises(
        nint block,
        Action<EventHandler> subscribe,
        Action<EventHandler> unsubscribe)
    {
        Assert.NotEqual(0, block);
        var literal = (ObjcBlockLiteral*)block;
        Assert.NotEqual(0, literal->Isa);
        Assert.NotEqual(0, (nint)literal->Invoke);
        Assert.NotEqual(0, literal->Descriptor);

        var count = 0;
        EventHandler handler = (_, _) => Interlocked.Increment(ref count);
        subscribe(handler);
        try
        {
            var status = literal->Invoke(block, 0);
            Assert.Equal(0, status);
            Assert.Equal(1, Volatile.Read(ref count));
        }
        finally
        {
            unsubscribe(handler);
        }
    }
}

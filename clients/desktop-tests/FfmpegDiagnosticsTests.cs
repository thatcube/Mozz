using Mozz.Desktop.Audio;
using Mozz.Desktop.Audio.Decoding;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Covers the two halves of the "cannot play music" fix: finding ffmpeg when a
/// GUI-launched app has a minimal PATH, and turning a silent decode failure into
/// an honest, credential-free message the listener can act on.
///
/// None of these spawn ffmpeg — the locator is probed with an injected
/// filesystem and the pipeline is driven with a fake decoder — so the run stays
/// deterministic and cross-platform on CI.
/// </summary>
public class FfmpegDiagnosticsTests
{
    private const string PlexUrl =
        "https://192-168-68-71.abc123.plex.direct:32400/library/parts/39388/1750307723/file.m4a" +
        "?X-Plex-Token=jMSwEeko5ragiHRKbtSECRET";

    // --- Redaction: a token must never reach a status bar or a log ---

    [Fact]
    public void Redact_RemovesPlexTokenValue_KeepsTheRestOfTheUrl()
    {
        var redacted = AudioDiagnostics.Redact(PlexUrl);

        Assert.DoesNotContain("jMSwEeko5ragiHRKbtSECRET", redacted);
        Assert.Contains("X-Plex-Token=REDACTED", redacted);
        // The identifying, non-secret part of the URL is preserved.
        Assert.Contains("/library/parts/39388/", redacted);
    }

    [Theory]
    [InlineData("http://host/a?api_key=deadbeef", "api_key=REDACTED")]
    [InlineData("http://host/a?foo=1&access_token=zzz9", "access_token=REDACTED")]
    [InlineData("http://host/a?token=abc&b=2", "token=REDACTED")]
    public void Redact_CoversTheCommonCredentialParameters(string url, string expected)
    {
        var redacted = AudioDiagnostics.Redact(url);
        Assert.Contains(expected, redacted);
        Assert.DoesNotContain("deadbeef", redacted);
        Assert.DoesNotContain("zzz9", redacted);
    }

    [Fact]
    public void Redact_StripsTokenGivenAsAHeaderStyleColonValue()
    {
        var redacted = AudioDiagnostics.Redact("X-Plex-Token: jMSwEekoSECRET");
        Assert.DoesNotContain("jMSwEekoSECRET", redacted);
        Assert.Contains("REDACTED", redacted);
    }

    [Fact]
    public void Redact_LeavesAnOrdinaryUrlUntouched()
    {
        const string url = "https://example.com/song.m4a?bitrate=320";
        Assert.Equal(url, AudioDiagnostics.Redact(url));
    }

    // --- Summarising ffmpeg's stderr into one readable, token-free line ---

    [Fact]
    public void SummariseFfmpeg_TurnsACertFailureIntoPlainWords_WithoutTheToken()
    {
        // The shape ffmpeg 9 actually emits for a self-signed / unverifiable cert.
        var stderr =
            "[tls @ 0x72cc34000] error: certificate verify failed\n" +
            $"[https @ 0x600001] Failed to open https://host/file.m4a?X-Plex-Token=SECRETVALUE\n" +
            "Error opening input: Input/output error";

        var summary = AudioDiagnostics.SummariseFfmpeg(stderr);

        Assert.Contains("certificate", summary, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("SECRETVALUE", summary);
        // The component/address prefix is noise and should be gone.
        Assert.DoesNotContain("0x72cc34000", summary);
    }

    [Theory]
    [InlineData("[http @ 0x1] Server returned 401 Unauthorized", "token")]
    [InlineData("[http @ 0x1] Server returned 404 Not Found", "404")]
    [InlineData("[tcp @ 0x1] Connection refused", "refused")]
    [InlineData("[tcp @ 0x1] Connection timed out", "timed out")]
    public void SummariseFfmpeg_RecognisesTheCommonNetworkFailures(string stderr, string expectFragment)
    {
        var summary = AudioDiagnostics.SummariseFfmpeg(stderr);
        Assert.Contains(expectFragment, summary, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SummariseFfmpeg_IsEmptyWhenThereIsNothingToSay()
    {
        Assert.Equal("", AudioDiagnostics.SummariseFfmpeg(null));
        Assert.Equal("", AudioDiagnostics.SummariseFfmpeg("   "));
    }

    [Fact]
    public void DescribeFfmpegFailure_LeadsWithTheReasonAndKeepsTheExitCode()
    {
        var msg = AudioDiagnostics.DescribeFfmpegFailure(251, "[tls @ 0x1] certificate verify failed");

        Assert.Contains("certificate", msg, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("ffmpeg exit 251", msg);
    }

    [Fact]
    public void DescribeFfmpegFailure_StillSaysSomethingWhenStderrIsEmpty()
    {
        var msg = AudioDiagnostics.DescribeFfmpegFailure(1, "");
        Assert.False(string.IsNullOrWhiteSpace(msg));
        Assert.Contains("ffmpeg exit 1", msg);
    }

    // --- The open-failure message: reason first, token gone ---

    [Fact]
    public void DescribeOpenFailure_PutsReasonFirstAndRedactsTheUrl()
    {
        var msg = AudioDiagnostics.DescribeOpenFailure(
            PlexUrl, "FFmpeg could not be started ('ffmpeg'). Install FFmpeg or set MOZZ_FFMPEG.");

        // Reason leads, so a status bar that truncates keeps the actionable part.
        Assert.StartsWith("FFmpeg could not be started", msg);
        Assert.DoesNotContain("jMSwEeko5ragiHRKbtSECRET", msg);
    }

    // --- The locator: the actual root-cause fix ---

    [Fact]
    public void Candidates_IncludeHomebrewBin_OnMac_SoAMinimalGuiPathStillFindsFfmpeg()
    {
        var candidates = FfmpegLocator.Candidates("/Apps/Mozz.app/Contents/MacOS", isWindows: false).ToList();
        Assert.Contains("/opt/homebrew/bin/ffmpeg", candidates);
        Assert.Contains("/usr/local/bin/ffmpeg", candidates);
        // The copy shipped beside the app is tried before anything on the system.
        Assert.Equal("/Apps/Mozz.app/Contents/MacOS/ffmpeg", candidates[0]);
    }

    [Fact]
    public void Resolve_PrefersAnExistingWellKnownPath_OverTheBareName()
    {
        var resolved = FfmpegLocator.Resolve(
            "/Apps/Mozz.app/Contents/MacOS", isWindows: false, mozzOverride: null,
            exists: p => p == "/opt/homebrew/bin/ffmpeg");

        Assert.Equal("/opt/homebrew/bin/ffmpeg", resolved);
    }

    [Fact]
    public void Resolve_FallsBackToTheBareName_WhenNothingConcreteExists()
    {
        Assert.Equal("ffmpeg", FfmpegLocator.Resolve("/app", false, null, _ => false));
        Assert.Equal("ffmpeg.exe", FfmpegLocator.Resolve(@"C:\app", true, null, _ => false));
    }

    [Fact]
    public void Resolve_HonoursAnExplicitOverride_EvenIfItDoesNotExist()
    {
        // A wrong MOZZ_FFMPEG should surface as a named error, not be silently ignored.
        var resolved = FfmpegLocator.Resolve("/app", false, "/custom/ffmpeg", _ => false);
        Assert.Equal("/custom/ffmpeg", resolved);
    }

    // --- End to end: a failing decoder now reaches the listener ---

    [Fact]
    public void PcmPipeline_SurfacesADecoderFailure_AsAnError_InsteadOfSilentEnd()
    {
        const int rate = 48000, ch = 2;
        const string reason = "the server’s TLS certificate could not be verified (ffmpeg exit 251)";

        using var pipe = new PcmPipeline(rate, ch, ringSeconds: 2.0);
        string? reported = null;
        using var errored = new ManualResetEventSlim(false);
        pipe.Error += m => { reported = m; errored.Set(); };

        pipe.LoadCurrent(new FailingDecoder(rate, ch, reason), new AudioSource("mem://bad"), "bad");

        var buf = new float[512 * ch];
        int guard = 0;
        while (!errored.IsSet && guard++ < 100_000)
            pipe.Render(buf);

        Assert.True(errored.IsSet, "a decoder that failed should raise Error, not end silently");
        Assert.Equal(reason, reported);
    }

    [Fact]
    public void PcmPipeline_DoesNotCryWolf_OnAnHonestEndOfTrack()
    {
        const int rate = 48000, ch = 2, frames = 4800;
        var dec = new WavPcmDecoder(
            new MemoryStream(WavTestSignal.SineFloat(rate, ch, 0, frames, 440.0)), rate, ch);

        using var pipe = new PcmPipeline(rate, ch, ringSeconds: 2.0);
        int errors = 0;
        using var ended = new ManualResetEventSlim(false);
        pipe.Error += _ => Interlocked.Increment(ref errors);
        pipe.PlaybackEnded += () => ended.Set();

        pipe.LoadCurrent(dec, new AudioSource("mem://ok"), "ok");

        var buf = new float[512 * ch];
        int guard = 0;
        while (!ended.IsSet && guard++ < 100_000)
            pipe.Render(buf);

        Thread.Sleep(50); // let any stray notification drain
        Assert.Equal(0, errors);
    }

    /// <summary>
    /// A decoder that produces no audio and reports a failure — the shape of an
    /// ffmpeg process that died on a bad certificate before writing a frame.
    /// </summary>
    private sealed class FailingDecoder(int rate, int channels, string reason)
        : IPcmDecoder, IDecoderDiagnostics
    {
        public int SampleRate => rate;
        public int Channels => channels;
        public TimeSpan? Duration => null;
        public bool CanSeek => false;
        public int ReadFrames(Span<float> destination, int frameCount) => 0;
        public void Seek(TimeSpan position) { }
        public bool TryGetFailure(out string r) { r = reason; return true; }
        public void Dispose() { }
    }
}

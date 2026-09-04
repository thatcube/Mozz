using Mozz.Desktop.Audio;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Covers <see cref="AudioDiagnostics"/>: turning a decode or open failure into
/// an honest, credential-free line a listener can act on, and never letting a
/// token reach a status bar or a log.
///
/// The audio engine now decodes in Rust rather than by spawning ffmpeg, so the
/// old "find ffmpeg on a minimal PATH" locator and the managed-pipeline
/// end-to-end tests are gone with it. The redaction and message-shaping rules
/// tested here still matter: <see cref="Native.RustAudioEngine"/> routes its
/// open-failure messages through <see cref="AudioDiagnostics.DescribeOpenFailure"/>,
/// which redacts exactly as these tests require. The ffmpeg-stderr summarisers
/// are retained on <see cref="AudioDiagnostics"/> and exercised here too; they
/// are no longer wired to a live subprocess in the desktop app.
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

    // --- Summarising a failure's stderr into one readable, token-free line ---

    [Fact]
    public void SummariseFfmpeg_TurnsACertFailureIntoPlainWords_WithoutTheToken()
    {
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
}

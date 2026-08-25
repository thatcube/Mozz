using Mozz.Desktop.Audio;
using Mozz.Desktop.Audio.Decoding;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The honest gapless proof, without a sound card. One continuous sine is split
/// into two "tracks"; the second is preloaded; the pipeline is drained exactly as
/// the audio device would drain it. If the hand-off is sample-accurate the drained
/// stream is bit-for-bit the original continuous sine across the seam.
/// </summary>
public class PcmPipelineGaplessTests
{
    [Fact]
    public void FlowsAcrossPreloadedBoundary_WithoutGapOrClick()
    {
        const int rate = 48000, ch = 2;
        const double freq = 441.0;
        const int framesA = 24000; // 0.5 s
        const int framesB = 24000; // 0.5 s
        int total = framesA + framesB;

        // Two contiguous halves of ONE sine (B is phased to continue from A).
        var decA = new WavPcmDecoder(new MemoryStream(WavTestSignal.SineFloat(rate, ch, 0, framesA, freq)), rate, ch);
        var decB = new WavPcmDecoder(new MemoryStream(WavTestSignal.SineFloat(rate, ch, framesA, framesB, freq)), rate, ch);

        using var pipe = new PcmPipeline(rate, ch, ringSeconds: 3.0);

        int changedCount = 0;
        object? changedToken = null;
        using var ended = new ManualResetEventSlim(false);
        pipe.TrackChanged += t => { changedToken = t; Interlocked.Increment(ref changedCount); };
        pipe.PlaybackEnded += () => ended.Set();

        pipe.LoadCurrent(decA, new AudioSource("mem://a"), "A");
        pipe.PreloadNext(decB, new AudioSource("mem://b"), "B");

        // Let the pump decode the whole 1 s into the 3 s ring before we drain,
        // so a slow reader can never underrun and desync the frame mapping.
        Thread.Sleep(500);

        var captured = new List<float>(total * ch + rate);
        var buf = new float[512 * ch];
        int guard = 0;
        while (!ended.IsSet && guard++ < 100_000)
        {
            pipe.Render(buf);
            captured.AddRange(buf);
        }
        // Flush any trailing partial buffer the loop may have missed.
        pipe.Render(buf);
        captured.AddRange(buf);

        // The queue advanced exactly once, into the track we preloaded.
        Assert.Equal(1, changedCount);
        Assert.Equal("B", changedToken);
        Assert.True(ended.IsSet, "playback should have ended after the queue drained");

        // Every frame of the drained stream equals the single continuous sine —
        // this is the gapless guarantee. Trim two frames at the very end to stay
        // clear of the final-buffer padding.
        for (int i = 0; i < total - 2; i++)
        {
            float expected = WavTestSignal.Expected(i, rate, freq);
            float left = captured[i * ch];
            float right = captured[i * ch + 1];
            Assert.True(Math.Abs(left - expected) < 1e-3, $"left discontinuity at frame {i}: {left} vs {expected}");
            Assert.True(Math.Abs(right - expected) < 1e-3, $"right discontinuity at frame {i}: {right} vs {expected}");
        }

        // And point the microscope right at the seam: the last sample of A and the
        // first sample of B must be consecutive samples of the same wave.
        float lastOfA = captured[(framesA - 1) * ch];
        float firstOfB = captured[framesA * ch];
        Assert.True(Math.Abs(lastOfA - WavTestSignal.Expected(framesA - 1, rate, freq)) < 1e-3);
        Assert.True(Math.Abs(firstOfB - WavTestSignal.Expected(framesA, rate, freq)) < 1e-3);
    }

    /// <summary>
    /// A preload that arrives after the decoder has drained, but before the
    /// listener has heard the end, must still be stitched in.
    ///
    /// The pump reads ahead by the ring's depth, so a decoder finishes seconds
    /// before the audio does. The view model preloads the moment a track starts
    /// and never hits this — but resolving the next track's URL is a network
    /// round trip, and on a slow server or a very short track it can land in
    /// that window. This test reproduces it deliberately by waiting until the
    /// decoder has certainly finished before preloading at all: without the
    /// recovery the preload is silently dropped, playback ends, and a gapless
    /// album gets a gap in the middle of it.
    /// </summary>
    [Fact]
    public void PreloadArrivingAfterTheDecoderDrained_IsStillStitchedIn()
    {
        const int rate = 48000, ch = 2;
        const double freq = 441.0;
        const int framesA = 24000, framesB = 24000;
        int total = framesA + framesB;

        var decA = new WavPcmDecoder(new MemoryStream(WavTestSignal.SineFloat(rate, ch, 0, framesA, freq)), rate, ch);
        var decB = new WavPcmDecoder(new MemoryStream(WavTestSignal.SineFloat(rate, ch, framesA, framesB, freq)), rate, ch);

        using var pipe = new PcmPipeline(rate, ch, ringSeconds: 3.0);

        int changedCount = 0;
        object? changedToken = null;
        using var ended = new ManualResetEventSlim(false);
        pipe.TrackChanged += t => { changedToken = t; Interlocked.Increment(ref changedCount); };
        pipe.PlaybackEnded += () => ended.Set();

        pipe.LoadCurrent(decA, new AudioSource("mem://a"), "A");

        // The whole of A fits in the 3 s ring, so after this the decoder is done
        // and nothing has been rendered — exactly the window the fix addresses.
        Thread.Sleep(500);
        pipe.PreloadNext(decB, new AudioSource("mem://b"), "B");
        Thread.Sleep(300);

        var captured = new List<float>(total * ch + rate);
        var buf = new float[512 * ch];
        int guard = 0;
        while (!ended.IsSet && guard++ < 100_000)
        {
            pipe.Render(buf);
            captured.AddRange(buf);
        }
        pipe.Render(buf);
        captured.AddRange(buf);

        Assert.Equal(1, changedCount);
        Assert.Equal("B", changedToken);

        // Still sample-accurate: a late preload must produce the same continuous
        // wave an early one does, not merely avoid stopping.
        for (int i = 0; i < total - 2; i++)
        {
            float expected = WavTestSignal.Expected(i, rate, freq);
            Assert.True(Math.Abs(captured[i * ch] - expected) < 1e-3,
                $"discontinuity at frame {i}: {captured[i * ch]} vs {expected}");
        }
    }

    /// <summary>
    /// The other side of that boundary: once the end has actually been heard,
    /// a preload is genuinely too late and must not resurrect playback.
    /// </summary>
    [Fact]
    public void PreloadArrivingAfterTheEndWasHeard_DoesNotResurrectPlayback()
    {
        const int rate = 48000, ch = 2, frames = 4800;
        var decA = new WavPcmDecoder(new MemoryStream(WavTestSignal.SineFloat(rate, ch, 0, frames, 440.0)), rate, ch);
        var decB = new WavPcmDecoder(new MemoryStream(WavTestSignal.SineFloat(rate, ch, 0, frames, 440.0)), rate, ch);

        using var pipe = new PcmPipeline(rate, ch, ringSeconds: 2.0);
        int changedCount = 0;
        using var ended = new ManualResetEventSlim(false);
        pipe.TrackChanged += _ => Interlocked.Increment(ref changedCount);
        pipe.PlaybackEnded += () => ended.Set();

        pipe.LoadCurrent(decA, new AudioSource("mem://a"), "A");
        Thread.Sleep(200);

        var buf = new float[512 * ch];
        int guard = 0;
        while (!ended.IsSet && guard++ < 100_000) pipe.Render(buf);
        Assert.True(ended.IsSet);

        pipe.PreloadNext(decB, new AudioSource("mem://b"), "B");
        Thread.Sleep(200);
        for (int i = 0; i < 10; i++) pipe.Render(buf);

        Assert.Equal(0, changedCount);
        Assert.Equal(PlaybackState.Stopped, pipe.State);
    }

    [Fact]
    public void EndOfQueue_RaisesPlaybackEnded()
    {
        const int rate = 48000, ch = 2, frames = 4800;
        var dec = new WavPcmDecoder(new MemoryStream(WavTestSignal.SineFloat(rate, ch, 0, frames, 440.0)), rate, ch);

        using var pipe = new PcmPipeline(rate, ch, ringSeconds: 2.0);
        using var ended = new ManualResetEventSlim(false);
        pipe.PlaybackEnded += () => ended.Set();

        pipe.LoadCurrent(dec, new AudioSource("mem://only"), "only");
        Thread.Sleep(200);

        var buf = new float[512 * ch];
        int guard = 0;
        while (!ended.IsSet && guard++ < 100_000)
            pipe.Render(buf);

        Assert.True(ended.IsSet, "PlaybackEnded should fire once a single-track queue drains");
        Assert.Equal(PlaybackState.Stopped, pipe.State);
        Assert.True(pipe.Position.TotalSeconds > 0.05, "position should have advanced during playback");
    }
}

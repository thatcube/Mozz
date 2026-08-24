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

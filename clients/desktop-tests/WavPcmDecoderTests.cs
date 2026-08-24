using Mozz.Desktop.Audio.Decoding;
using Xunit;

namespace Mozz.Desktop.Tests;

public class WavPcmDecoderTests
{
    [Fact]
    public void DecodesEveryFrame_IncludingTheLast()
    {
        // The last-frame fix matters for gapless: dropping it would gap every
        // track boundary. Assert the decoder emits exactly frameCount frames.
        const int rate = 48000, ch = 2, frames = 1000;
        var wav = WavTestSignal.SineFloat(rate, ch, 0, frames, 440.0);

        using var dec = new WavPcmDecoder(new MemoryStream(wav), rate, ch);
        Assert.Equal(rate, dec.SampleRate);
        Assert.Equal(ch, dec.Channels);

        var outBuf = new float[frames * ch];
        int total = 0;
        // Read in small chunks to exercise the read-ahead across calls.
        while (total < frames)
        {
            int got = dec.ReadFrames(outBuf.AsSpan(total * ch, (frames - total) * ch), Math.Min(128, frames - total));
            if (got == 0) break;
            total += got;
        }

        Assert.Equal(frames, total);
        // First, last and a middle frame must all match the reference sine exactly.
        Assert.Equal(WavTestSignal.Expected(0, rate, 440.0), outBuf[0], 5);
        Assert.Equal(WavTestSignal.Expected(500, rate, 440.0), outBuf[500 * ch], 5);
        Assert.Equal(WavTestSignal.Expected(frames - 1, rate, 440.0), outBuf[(frames - 1) * ch], 5);
    }

    [Fact]
    public void UpmixesMonoToStereo()
    {
        const int rate = 48000, frames = 200;
        var wav = WavTestSignal.SineFloat(rate, channels: 1, startFrame: 0, frameCount: frames, frequencyHz: 300.0);

        using var dec = new WavPcmDecoder(new MemoryStream(wav), rate, targetChannels: 2);
        var outBuf = new float[frames * 2];
        int got = dec.ReadFrames(outBuf, frames);

        Assert.Equal(frames, got);
        // Left and right must be identical after the mono upmix.
        for (int i = 0; i < frames; i++)
            Assert.Equal(outBuf[i * 2], outBuf[i * 2 + 1], 6);
    }

    [Fact]
    public void Seek_RepositionsToRequestedFrame()
    {
        const int rate = 48000, ch = 1, frames = 48000;
        var wav = WavTestSignal.SineFloat(rate, ch, 0, frames, 440.0);
        using var dec = new WavPcmDecoder(new MemoryStream(wav), rate, ch);

        // 0.5 s is exact in TimeSpan ticks, so it lands unambiguously on frame 24000.
        dec.Seek(TimeSpan.FromSeconds(0.5));
        var one = new float[1];
        Assert.Equal(1, dec.ReadFrames(one, 1));
        Assert.Equal(WavTestSignal.Expected(24000, rate, 440.0), one[0], 4);
    }
}

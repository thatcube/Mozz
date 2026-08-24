using Mozz.Desktop.Audio;
using Mozz.Desktop.Audio.Dsp;

namespace Mozz.Desktop.Tests;

public class EqualizerTests
{
    private static float[] Sine(int rate, int frames, double freq, double amp = 0.5)
    {
        var buf = new float[frames];
        for (int i = 0; i < frames; i++)
            buf[i] = (float)(amp * Math.Sin(2 * Math.PI * freq * i / rate));
        return buf;
    }

    private static double Rms(ReadOnlySpan<float> s, int from)
    {
        double sum = 0;
        for (int i = from; i < s.Length; i++) sum += s[i] * (double)s[i];
        return Math.Sqrt(sum / (s.Length - from));
    }

    [Fact]
    public void Disabled_IsExactPassthrough()
    {
        var eq = new TenBandEqualizer(48000, 1);
        eq.Configure(EqualizerSettings.Flat().Bands, enabled: false);

        var signal = Sine(48000, 1000, 1000);
        var work = (float[])signal.Clone();
        eq.Process(work, work.Length);

        Assert.Equal(signal, work);
    }

    [Fact]
    public void FlatEnabled_IsUnityGain()
    {
        var eq = new TenBandEqualizer(48000, 1);
        // Every band at 0 dB — a peaking biquad at 0 dB is the identity filter.
        var bands = Array.ConvertAll(EqualizerSettings.IsoCentres, f => new EqBand(f, 0.0));
        eq.Configure(bands, enabled: true);

        var signal = Sine(48000, 2000, 1000);
        var work = (float[])signal.Clone();
        eq.Process(work, work.Length);

        for (int i = 0; i < signal.Length; i++)
            Assert.Equal(signal[i], work[i], 4);
    }

    [Fact]
    public void CutBand_AttenuatesThatFrequency()
    {
        var eq = new TenBandEqualizer(48000, 1);
        var bands = Array.ConvertAll(EqualizerSettings.IsoCentres, f =>
            new EqBand(f, Math.Abs(f - 1000) < 1 ? -12.0 : 0.0));
        eq.Configure(bands, enabled: true);

        var signal = Sine(48000, 4800, 1000);
        var work = (float[])signal.Clone();
        eq.Process(work, work.Length);

        // Skip the filter's settling transient, then compare steady-state energy.
        double before = Rms(signal, 512);
        double after = Rms(work, 512);
        Assert.True(after < before * 0.6, $"expected clear attenuation, got {after:F4} vs {before:F4}");
    }
}

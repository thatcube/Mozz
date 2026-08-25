namespace Mozz.Desktop.Audio.Dsp;

/// <summary>
/// A Direct Form I biquad — the standard second-order IIR section. The peaking
/// coefficients come from Robert Bristow-Johnson's Audio EQ Cookbook, the same
/// formulae every graphic EQ uses. State is per-instance, so one biquad is one
/// band of one channel.
/// </summary>
internal sealed class Biquad
{
    private double _b0 = 1, _b1, _b2, _a1, _a2;
    private double _x1, _x2, _y1, _y2;

    /// <summary>Configure this section as a peaking filter and reset nothing but the coefficients.</summary>
    public void SetPeaking(double sampleRate, double frequencyHz, double gainDb, double q)
    {
        if (q <= 0) q = 0.0001;
        frequencyHz = Math.Clamp(frequencyHz, 1.0, sampleRate * 0.5 - 1.0);

        double a = Math.Pow(10.0, gainDb / 40.0);
        double w0 = 2.0 * Math.PI * frequencyHz / sampleRate;
        double cos = Math.Cos(w0);
        double alpha = Math.Sin(w0) / (2.0 * q);

        double b0 = 1 + alpha * a;
        double b1 = -2 * cos;
        double b2 = 1 - alpha * a;
        double a0 = 1 + alpha / a;
        double a1 = -2 * cos;
        double a2 = 1 - alpha / a;

        _b0 = b0 / a0;
        _b1 = b1 / a0;
        _b2 = b2 / a0;
        _a1 = a1 / a0;
        _a2 = a2 / a0;
    }

    public void Reset() => _x1 = _x2 = _y1 = _y2 = 0;

    public float Process(float input)
    {
        double x0 = input;
        double y0 = _b0 * x0 + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
        _x2 = _x1; _x1 = x0;
        _y2 = _y1; _y1 = y0;
        return (float)y0;
    }
}

/// <summary>
/// A ten-band parametric equaliser over interleaved stereo. Each band is a
/// peaking biquad, and each channel keeps its own filter state so the stereo
/// image is preserved. Processing is in place on the pump thread, well ahead of
/// the audio callback, so the cost never lands on the device.
/// </summary>
internal sealed class TenBandEqualizer(int sampleRate, int channels)
{
    private readonly int _channels = channels;
    private readonly int _sampleRate = sampleRate;
    private Biquad[][] _bands = [];
    private volatile bool _enabled;
    private double _preamp = 1.0;

    public bool Enabled => _enabled;

    /// <summary>Rebuild the filter bank from new settings. Cheap enough to call whenever the user drags a slider.</summary>
    public void Configure(IReadOnlyList<EqBand> bands, bool enabled, double preampDb = 0)
    {
        var next = new Biquad[bands.Count][];
        for (int b = 0; b < bands.Count; b++)
        {
            next[b] = new Biquad[_channels];
            for (int c = 0; c < _channels; c++)
            {
                var biquad = new Biquad();
                biquad.SetPeaking(_sampleRate, bands[b].FrequencyHz, bands[b].GainDb, bands[b].Q);
                next[b][c] = biquad;
            }
        }

        _bands = next;
        _enabled = enabled && bands.Count > 0;
        Volatile.Write(ref _preamp, Math.Pow(10.0, Math.Clamp(preampDb, -12.0, 12.0) / 20.0));
    }

    /// <summary>Clear every filter's state — used at a load or seek so nothing carries a click across the discontinuity.</summary>
    public void Reset()
    {
        var bands = _bands;
        for (int b = 0; b < bands.Length; b++)
            for (int c = 0; c < bands[b].Length; c++)
                bands[b][c].Reset();
    }

    /// <summary>Filter <paramref name="interleaved"/> in place. A no-op when disabled.</summary>
    public void Process(Span<float> interleaved, int frameCount)
    {
        if (!_enabled) return;
        var bands = _bands;
        if (bands.Length == 0) return;

        for (int i = 0; i < frameCount; i++)
        {
            int baseIdx = i * _channels;
            for (int c = 0; c < _channels; c++)
            {
                float sample = interleaved[baseIdx + c];
                for (int b = 0; b < bands.Length; b++)
                    sample = bands[b][c].Process(sample);
                interleaved[baseIdx + c] = (float)(sample * Volatile.Read(ref _preamp));
            }
        }
    }
}

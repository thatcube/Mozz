using System.Text.Json.Serialization;
using Mozz.Desktop.Audio;

namespace Mozz.Desktop.Core;

public sealed record DesktopEqualizerProfile(
    [property: JsonPropertyName("gains")] IReadOnlyList<double> Gains,
    [property: JsonPropertyName("preampDB")] double PreampDB = 0)
{
    public const int BandCount = 10;
    public const double MinGainDb = -12;
    public const double MaxGainDb = 12;

    public static DesktopEqualizerProfile Flat =>
        new(Enumerable.Repeat(0.0, BandCount).ToArray(), 0);

    public DesktopEqualizerProfile Normalized()
    {
        var gains = Gains.Take(BandCount).Select(ClampGain).ToList();
        while (gains.Count < BandCount) gains.Add(0);
        return new DesktopEqualizerProfile(gains, ClampGain(PreampDB));
    }

    public DesktopEqualizerProfile WithGain(int index, double gain)
    {
        var normalized = Normalized();
        var gains = normalized.Gains.ToArray();
        if ((uint)index < gains.Length) gains[index] = ClampGain(gain);
        return normalized with { Gains = gains };
    }

    public DesktopEqualizerProfile WithPreamp(double preampDB) =>
        Normalized() with { PreampDB = ClampGain(preampDB) };

    public EqualizerSettings ToAudioSettings(bool enabled)
    {
        var normalized = Normalized();
        return new EqualizerSettings(enabled, EqualizerSettings.IsoCentres
            .Select((frequency, index) => new EqBand(frequency, normalized.Gains[index]))
            .ToArray(), normalized.PreampDB);
    }

    public static string FrequencyLabel(int band) =>
        band >= 0 && band < EqualizerSettings.IsoCentres.Length
            ? FrequencyLabel(EqualizerSettings.IsoCentres[band])
            : string.Empty;

    public static string FrequencyLabel(double hz) =>
        hz >= 1000
            ? hz % 1000 == 0 ? $"{(int)(hz / 1000)}k" : $"{hz / 1000:0.#}k"
            : $"{(int)hz}";

    public static double ClampGain(double value) =>
        double.IsFinite(value) ? Math.Clamp(value, MinGainDb, MaxGainDb) : 0;
}

public enum DesktopEqualizerPreset
{
    Flat,
    BassBoost,
    TrebleBoost,
    Vocal,
    Acoustic,
    Electronic,
    Rock,
}

public static class DesktopEqualizerPresets
{
    public static readonly DesktopEqualizerPreset[] All =
    [
        DesktopEqualizerPreset.Flat,
        DesktopEqualizerPreset.BassBoost,
        DesktopEqualizerPreset.TrebleBoost,
        DesktopEqualizerPreset.Vocal,
        DesktopEqualizerPreset.Acoustic,
        DesktopEqualizerPreset.Electronic,
        DesktopEqualizerPreset.Rock,
    ];

    public static string DisplayName(this DesktopEqualizerPreset preset) => preset switch
    {
        DesktopEqualizerPreset.Flat => "Flat",
        DesktopEqualizerPreset.BassBoost => "Bass Boost",
        DesktopEqualizerPreset.TrebleBoost => "Treble Boost",
        DesktopEqualizerPreset.Vocal => "Vocal",
        DesktopEqualizerPreset.Acoustic => "Acoustic",
        DesktopEqualizerPreset.Electronic => "Electronic",
        DesktopEqualizerPreset.Rock => "Rock",
        _ => preset.ToString(),
    };

    public static DesktopEqualizerProfile Profile(this DesktopEqualizerPreset preset) => new(preset switch
    {
        DesktopEqualizerPreset.Flat => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        DesktopEqualizerPreset.BassBoost => [6.0, 5.0, 4.0, 2.0, 0.5, 0, 0, 0, 0, 0],
        DesktopEqualizerPreset.TrebleBoost => [0, 0, 0, 0, 0, 0.5, 2.0, 4.0, 5.0, 6.0],
        DesktopEqualizerPreset.Vocal => [-2.0, -1.5, -1.0, 1.0, 3.0, 4.0, 3.5, 2.0, 0.5, -0.5],
        DesktopEqualizerPreset.Acoustic => [3.0, 2.5, 1.5, 0.5, 1.5, 1.5, 2.0, 2.5, 2.0, 1.5],
        DesktopEqualizerPreset.Electronic => [4.0, 3.5, 1.5, 0, -1.5, 1.5, 0.5, 1.5, 3.5, 4.5],
        DesktopEqualizerPreset.Rock => [4.0, 3.0, 1.5, 0, -0.5, 0.5, 1.5, 3.0, 3.5, 3.5],
        _ => throw new ArgumentOutOfRangeException(nameof(preset), preset, null),
    });

    public static DesktopEqualizerPreset? Matching(DesktopEqualizerProfile profile)
    {
        var gains = profile.Normalized().Gains;
        return All.FirstOrDefault(preset => preset.Profile().Gains.SequenceEqual(gains));
    }
}

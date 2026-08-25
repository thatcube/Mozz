namespace Mozz.Desktop.Audio.Dsp;

/// <summary>
/// Turns ReplayGain metadata into a linear multiplier. ReplayGain is expressed
/// in dB relative to a reference loudness; applying it is a single scalar per
/// track, chosen by mode and topped up with a global pre-amp.
/// </summary>
internal static class ReplayGain
{
    /// <summary>dB → linear amplitude.</summary>
    public static double DbToLinear(double db) => Math.Pow(10.0, db / 20.0);

    /// <summary>
    /// The multiplier to apply to a source given the chosen mode and pre-amp.
    /// Falls back cleanly: album mode uses the track tag when no album tag exists,
    /// and a missing tag means unity gain rather than silence.
    /// </summary>
    public static double LinearFor(
        ReplayGainMode mode,
        double preampDb,
        double? trackDb,
        double? albumDb)
    {
        if (mode == ReplayGainMode.Off)
            return DbToLinear(preampDb);

        double? gain = mode == ReplayGainMode.Album ? (albumDb ?? trackDb) : (trackDb ?? albumDb);
        double totalDb = preampDb + (gain ?? 0.0);
        return DbToLinear(totalDb);
    }
}

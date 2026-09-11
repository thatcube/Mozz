namespace Mozz.Desktop.ViewModels;

/// <summary>
/// How a lyric line is drawn given its distance from the line being sung.
///
/// The numbers are the phones' numbers, deliberately: iOS's
/// <c>PlayerLyricsPanel</c> and Android's <c>LyricDepth</c> already agree on
/// them, and a lyrics column that dims on a different curve on the desktop
/// would read as a different app rather than the same one on a bigger screen.
///
/// Brightness says which line is being sung; softness says how far from it you
/// are looking.
/// </summary>
public static class LyricDepth
{
    /// <summary>How many lines either side of the current one stay perfectly sharp.</summary>
    public const int SharpRadius = 1;

    /// <summary>Added softness, in pixels, per line beyond the sharp radius.</summary>
    public const double BlurStep = 1.1;

    /// <summary>The most any line is softened, however far away it is.</summary>
    public const double BlurCeiling = 3.5;

    /// <summary>How far the column dissolves into the backdrop at its top edge.</summary>
    public const double TopFade = 56;

    /// <summary>And at its bottom, where there is more still to come.</summary>
    public const double BottomFade = 72;

    /// <summary>
    /// Where the line being sung sits in the column: a third of the way down
    /// rather than dead centre, so there is more room to read ahead than behind.
    /// </summary>
    public const double FocusAnchor = 0.34;

    /// <summary>
    /// How visible a line is at <paramref name="distance"/> lines from the
    /// active one. A null distance means nothing is being sung — unsynced
    /// lyrics, or the run-up before the first timestamp — and then every line
    /// sits at one even brightness rather than one of them being arbitrarily
    /// picked out.
    /// </summary>
    public static double Opacity(int? distance) => distance switch
    {
        null => 0.8,
        0 => 1,
        1 => 0.4,
        2 => 0.28,
        _ => 0.2,
    };

    /// <summary>
    /// How soft a line is at <paramref name="distance"/> from the active one.
    ///
    /// The lines you are about to read stay SHARP. Softening starts a couple of
    /// lines out, so the blur reads as the column receding towards its edges
    /// rather than as a spotlight on one line: by the time a line is soft it is
    /// also close to scrolling off, which is the only place unreadable is the
    /// right answer.
    ///
    /// Blurring the immediate neighbours is the version that fights the reader.
    /// The next line is the one being sung in a moment and the eye is already on
    /// it; softening it means spending the bar squinting at words you are about
    /// to hear. Dimming is enough on its own to say which line is current.
    /// </summary>
    public static double BlurRadius(int? distance)
    {
        if (distance is not { } d) return 0;
        var beyond = d - SharpRadius;
        if (beyond <= 0) return 0;
        return System.Math.Min(BlurCeiling, beyond * BlurStep);
    }
}

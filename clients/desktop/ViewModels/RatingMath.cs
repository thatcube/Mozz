namespace Mozz.Desktop.ViewModels;

/// <summary>
/// Pure geometry → rating mapping, shared by every way the desktop sets a
/// rating so a click and a drag cannot disagree.
///
/// A port of iOS's <c>RatingMath</c>, which Android's <c>ratingAtX</c> is also a
/// port of. The three must agree: the same gesture across the same strip has to
/// mean the same rating on all three clients, or a library rated on the phone
/// reads back differently on the desktop.
/// </summary>
public static class RatingMath
{
    public const int StarCount = 5;

    /// <summary>Size of a star glyph in the strip.</summary>
    public const double StarSize = 22;

    /// <summary>Gap between stars.</summary>
    public const double Spacing = 6;

    /// <summary>Total width the strip occupies, stars laid out in fixed cells.</summary>
    public static double StripWidth(double starSize = StarSize, double spacing = Spacing) =>
        StarCount * starSize + (StarCount - 1) * spacing;

    /// <summary>
    /// Map a horizontal position measured from the FIRST star's leading edge to a
    /// snapped rating. The left half of star <c>i</c> yields <c>i - 0.5</c> and the
    /// right half <c>i</c>, so the whole strip is reachable in half steps.
    ///
    /// A position left of the first star yields null — "clear". Dragging off the
    /// end is how a rating is taken away, and it has to be reachable without
    /// lifting the pointer.
    /// </summary>
    public static double? RatingAtX(double x, double starSize = StarSize, double spacing = Spacing)
    {
        if (x < 0) return null;
        var pitch = starSize + spacing;
        var index = (int)(x / pitch);
        if (index >= StarCount) return 5.0;
        var within = x - index * pitch;
        var value = within < starSize / 2 ? index + 0.5 : index + 1.0;
        return System.Math.Min(value, 5.0);
    }

    /// <summary>Trailing zeroes are noise on a star count: 4.0 reads as "4", 4.5 as "4.5".</summary>
    public static string Format(double value) =>
        value % 1.0 == 0.0 ? ((int)value).ToString() : value.ToString("0.0");

    /// <summary>"1 star", but "1.5 stars" — the only singular is exactly one.</summary>
    public static string Label(double value) =>
        value == 1.0 ? "1 star" : Format(value) + " stars";
}

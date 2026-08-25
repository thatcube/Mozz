using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Data;
using Avalonia.Media;

namespace Mozz.Desktop.Core;

/// <summary>
/// Turns a title into a stable colour, so artwork placeholders look deliberate
/// rather than broken.
///
/// A wall of identical grey squares reads as a loading failure. Giving each item
/// its own colour, derived from its name so it never changes between launches,
/// makes an un-fetched library look like a designed state — and once real
/// artwork arrives it simply covers this.
///
/// Hues are drawn from a fixed palette rather than the whole wheel: freely
/// generated hues collide with the crimson accent and produce muddy greens, so
/// the set is hand-picked to sit alongside it.
/// </summary>
public sealed class ArtworkPlaceholderConverter : IValueConverter
{
    public static readonly ArtworkPlaceholderConverter Instance = new();

    // Deep, desaturated tones. Album art is the loudest thing on the screen when
    // it exists; a placeholder should recede rather than compete.
    private static readonly (Color From, Color To)[] Palette =
    [
        (Color.Parse("#3A2C4E"), Color.Parse("#241C33")),
        (Color.Parse("#2C3E4E"), Color.Parse("#1C2833")),
        (Color.Parse("#4E3A2C"), Color.Parse("#33241C")),
        (Color.Parse("#2C4E3E"), Color.Parse("#1C3328")),
        (Color.Parse("#4E2C3A"), Color.Parse("#331C24")),
        (Color.Parse("#3E4E2C"), Color.Parse("#28331C")),
        (Color.Parse("#2C334E"), Color.Parse("#1C2033")),
        (Color.Parse("#4E4A2C"), Color.Parse("#33301C")),
    ];

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var text = value as string ?? string.Empty;
        var index = StableIndex(text, Palette.Length);
        var (from, to) = Palette[index];

        return new LinearGradientBrush
        {
            StartPoint = new Avalonia.RelativePoint(0, 0, Avalonia.RelativeUnit.Relative),
            EndPoint = new Avalonia.RelativePoint(1, 1, Avalonia.RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(from, 0),
                new GradientStop(to, 1),
            },
        };
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();

    /// <summary>
    /// FNV-1a rather than string.GetHashCode: .NET randomises string hashes per
    /// process, so the same album would change colour on every launch.
    /// </summary>
    private static int StableIndex(string text, int buckets)
    {
        unchecked
        {
            const uint offset = 2166136261;
            const uint prime = 16777619;
            var hash = offset;
            foreach (var c in text)
            {
                hash ^= c;
                hash *= prime;
            }
            return (int)(hash % (uint)buckets);
        }
    }
}

/// <summary>The first letter of a title, for the middle of a placeholder.</summary>
public sealed class InitialConverter : IValueConverter
{
    public static readonly InitialConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var text = (value as string)?.Trim();
        if (string.IsNullOrEmpty(text)) return "♪";
        var first = text.FirstOrDefault(char.IsLetterOrDigit);
        return first == default ? "♪" : char.ToUpperInvariant(first).ToString();
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>
/// Two-way binding between an enum property and a set of radio buttons.
///
/// `IsChecked="{Binding Kind, Converter=EnumMatch, ConverterParameter=Plex}"`
/// reads true when the property equals that member, and writes that member back
/// when the button is checked. Without this each option needs its own bool
/// property and its own command, which is three of each for three backends and
/// a fourth thing to forget when a backend is added.
/// </summary>
public sealed class EnumMatchConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is not null
           && parameter is string name
           && string.Equals(value.ToString(), name, StringComparison.OrdinalIgnoreCase);

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        // Only the button being *checked* carries information; the one being
        // unchecked would otherwise write a second, conflicting value.
        if (value is not true || parameter is not string name) return BindingOperations.DoNothing;

        var enumType = Nullable.GetUnderlyingType(targetType) ?? targetType;
        return enumType.IsEnum && Enum.TryParse(enumType, name, ignoreCase: true, out var parsed)
            ? parsed
            : BindingOperations.DoNothing;
    }
}

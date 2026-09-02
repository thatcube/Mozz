using Avalonia;
using Avalonia.Media;

namespace Mozz.Desktop.Core;

/// <summary>
/// The app's colours, in the three ways it can be painted.
///
/// Every one of these keys is referenced from XAML with <c>DynamicResource</c>,
/// so replacing the brush in the application's resource dictionary repaints the
/// whole window on the spot — no restart, no per-control plumbing.
///
/// The three sets are the same three the iPhone and the Android app have, tier
/// for tier and value for value where the two platforms have the same tier, so
/// that someone who uses Mozz on two of them is looking at one product. The
/// canonical ladder is in <c>Theme.kt</c> and <c>Color+Mozz.swift</c>.
/// </summary>
internal static class DesktopPalette
{
    /// <summary>
    /// Black is not a darker Dark. It is the mode where nothing takes its colour
    /// from the artwork: every background in the app is black, and a cover is
    /// only ever seen inside its own frame. What is left to separate one region
    /// from another is a hairline, so the rules are drawn brighter here than
    /// they are in Dim — on a true-black page a #17171B rule is not faint, it is
    /// invisible.
    ///
    /// The same rule, in the same words, is in <c>Theme.kt</c>,
    /// <c>MediaDetailScaffold.swift</c> and <c>NowPlayingMorph.swift</c>.
    /// </summary>
    public static void Apply(Application app, bool dark, bool blackout)
    {
        if (!dark)
        {
            Set(app, "AppBackground", "#F2F2F7");
            Set(app, "SidebarBackground", "#EBEBF0");
            Set(app, "BarBackground", "#FFFFFF");
            Set(app, "SurfaceRaised", "#FFFFFF");
            Set(app, "SurfaceHover", "#E6E6EC");
            Set(app, "SurfaceSelected", "#DCDCE4");
            Set(app, "Divider", "#DCDCDC");
            Set(app, "TextPrimary", "#0A0A0A");
            Set(app, "TextSecondary", "#6B6B6B");
            Set(app, "TextTertiary", "#98989F");
            // The deeper crimson on white. The bright one is tuned for a
            // near-black page and, on paper, reads as pink.
            Set(app, "Accent", "#B00023");
            Set(app, "AccentHover", "#C4102F");
            Set(app, "AccentDeep", "#8C001C");
            Set(app, "SliderTrackFill", "#C8C8D0");
            Set(app, "SliderTrackFillPointerOver", "#B8B8C2");
            Set(app, "SliderTrackFillPressed", "#B8B8C2");
            Set(app, "SliderTrackFillDisabled", "#E0E0E6");
            Set(app, "SliderTrackValueFill", "#B00023");
            Set(app, "SliderTrackValueFillPointerOver", "#C4102F");
            Set(app, "SliderTrackValueFillPressed", "#C4102F");
            Set(app, "SliderTrackValueFillDisabled", "#D8A8B0");
            Set(app, "SliderThumbBackground", "#1A1A1C");
            Set(app, "SliderThumbBackgroundPointerOver", "#000000");
            Set(app, "SliderThumbBackgroundPressed", "#000000");
            Set(app, "SliderThumbBackgroundDisabled", "#98989F");
            SetHeroScrim(app, "#F2F2F7");
            SetPlayerScrim(app, "#F2F2F7");
            SetSurfaceBorder(app, null);
            return;
        }

        Set(app, "AppBackground", blackout ? "#000000" : "#0B0B0D");
        Set(app, "SidebarBackground", blackout ? "#000000" : "#121214");
        Set(app, "BarBackground", blackout ? "#000000" : "#141416");
        // Black at rest, with `SurfaceBorder` doing the separating. Hover and
        // selection keep the smallest lift that still reads as feedback: they
        // are transient states rather than chrome, and a row that does nothing
        // under the pointer reads as broken rather than as restrained.
        Set(app, "SurfaceRaised", blackout ? "#000000" : "#1C1C20");
        Set(app, "SurfaceHover", blackout ? "#151515" : "#232328");
        Set(app, "SurfaceSelected", blackout ? "#1E1E1E" : "#2A2A30");
        Set(app, "Divider", blackout ? "#2A2A2A" : "#232327");
        Set(app, "TextPrimary", "#F2F2F4");
        Set(app, "TextSecondary", "#9A9AA2");
        Set(app, "TextTertiary", "#6A6A72");
        Set(app, "Accent", "#D8213F");
        Set(app, "AccentHover", "#E63A55");
        Set(app, "AccentDeep", "#B00023");
        Set(app, "SliderTrackFill", "#3A3A42");
        Set(app, "SliderTrackFillPointerOver", "#45454F");
        Set(app, "SliderTrackFillPressed", "#45454F");
        Set(app, "SliderTrackFillDisabled", "#2A2A30");
        Set(app, "SliderTrackValueFill", "#D8213F");
        Set(app, "SliderTrackValueFillPointerOver", "#E63A55");
        Set(app, "SliderTrackValueFillPressed", "#E63A55");
        Set(app, "SliderTrackValueFillDisabled", "#5A2A32");
        Set(app, "SliderThumbBackground", "#F2F2F4");
        Set(app, "SliderThumbBackgroundPointerOver", "#FFFFFF");
        Set(app, "SliderThumbBackgroundPressed", "#FFFFFF");
        Set(app, "SliderThumbBackgroundDisabled", "#6A6A72");
        SetHeroScrim(app, blackout ? "#000000" : "#0B0B0D");
        SetPlayerScrim(app, blackout ? "#000000" : "#0B0B0D");
        SetSurfaceBorder(app, blackout ? "#3A3A3A" : null);
    }

    /// <summary>
    /// The hairline that replaces elevation in Black.
    ///
    /// Passing null gives a transparent brush and a zero thickness, so every
    /// surface that opts into these two resources is untouched in Dim and Light
    /// — the border is not "off", it takes up no space at all, which matters
    /// because a 1px border would otherwise shift each card's contents.
    /// </summary>
    private static void SetSurfaceBorder(Application app, string? color)
    {
        app.Resources["SurfaceBorder"] = new SolidColorBrush(
            color is null ? Colors.Transparent : Color.Parse(color));
        app.Resources["SurfaceBorderThickness"] = new Thickness(color is null ? 0 : 1);
    }

    /// <summary>
    /// What sits between the player's blown-up cover and its text.
    ///
    /// It is mostly the page's OWN background rather than a black veil, and that
    /// is the whole point: a black scrim is only legible in a dark theme, and the
    /// desktop has a light one. Painting the page colour at high opacity leaves
    /// the cover reading as a tint of whatever theme is in effect, so the text on
    /// top can keep using TextPrimary and be correct in all three.
    ///
    /// It is denser at the bottom, where the controls are, than at the top, where
    /// there is only artwork to show off.
    /// </summary>
    private static void SetPlayerScrim(Application app, string background)
    {
        var opaque = Color.Parse(background);
        app.Resources["PlayerScrim"] = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(Color.FromArgb(0xB8, opaque.R, opaque.G, opaque.B), 0),
                new GradientStop(Color.FromArgb(0xE8, opaque.R, opaque.G, opaque.B), 0.55),
                new GradientStop(Color.FromArgb(0xF7, opaque.R, opaque.G, opaque.B), 1),
            },
        };
    }

    /// <summary>
    /// The wash under an artist banner's name, fading from nothing to the page's
    /// own background.
    ///
    /// It has to follow the palette. Baked to the Dim near-black, it left a grey
    /// haze over the bottom of the artwork in Black and a dark smear in Light —
    /// which is precisely the artwork-bleeding-into-the-page that Black exists
    /// to stop.
    /// </summary>
    private static void SetHeroScrim(Application app, string background)
    {
        var opaque = Color.Parse(background);
        app.Resources["HeroScrim"] = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(Color.FromArgb(0, opaque.R, opaque.G, opaque.B), 0),
                new GradientStop(Color.FromArgb(0xCC, opaque.R, opaque.G, opaque.B), 1),
            },
        };
    }

    private static void Set(Application app, string key, string color) =>
        app.Resources[key] = new SolidColorBrush(Color.Parse(color));
}

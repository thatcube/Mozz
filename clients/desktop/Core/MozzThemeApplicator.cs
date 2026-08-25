using Avalonia;
using Avalonia.Media;
using Avalonia.Styling;

namespace Mozz.Desktop.Core;

public static class MozzThemeApplicator
{
    public static MozzThemePalette Apply(Application app, string appearanceRaw, string darkStyleRaw)
    {
        var appearance = MozzTheme.ParseAppearance(appearanceRaw);
        var darkStyle = MozzTheme.ParseDarkStyle(darkStyleRaw);
        app.RequestedThemeVariant = RequestedThemeVariant(appearance);

        var systemTheme = app.ActualThemeVariant == ThemeVariant.Dark ? MozzSystemTheme.Dark : MozzSystemTheme.Light;
        var palette = MozzTheme.Palette(appearance, darkStyle, systemTheme);
        Apply(app, palette);
        return palette;
    }

    private static ThemeVariant RequestedThemeVariant(MozzAppearance appearance) => appearance switch
    {
        MozzAppearance.Light => ThemeVariant.Light,
        MozzAppearance.Dark => ThemeVariant.Dark,
        _ => ThemeVariant.Default,
    };

    private static void Apply(Application app, MozzThemePalette palette)
    {
        SetBrush(app, "Accent", palette.Brand);
        SetBrush(app, "AccentHover", palette.BrandHover);
        SetBrush(app, "AccentDeep", palette.BrandPressed);
        SetBrush(app, "Brand", palette.Brand);
        SetBrush(app, "AppBackground", palette.Background);
        SetBrush(app, "SidebarBackground", palette.SidebarBackground);
        SetBrush(app, "BarBackground", palette.BarBackground);
        SetBrush(app, "Surface", palette.Surface);
        SetBrush(app, "SurfaceRaised", palette.SurfaceRaised);
        SetBrush(app, "SurfaceHover", palette.SurfaceHover);
        SetBrush(app, "SurfaceSelected", palette.SurfaceSelected);
        SetBrush(app, "DetailBackground", palette.DetailBackground);
        SetBrush(app, "Divider", palette.Divider);
        SetBrush(app, "TextPrimary", palette.TextPrimary);
        SetBrush(app, "TextSecondary", palette.TextSecondary);
        SetBrush(app, "TextTertiary", palette.TextTertiary);
        SetBrush(app, "SearchBackground", palette.SearchBackground);
        SetBrush(app, "ArtworkFallbackPrimary", palette.ArtworkFallbackPrimary);
        SetBrush(app, "ArtworkFallbackSecondary", palette.ArtworkFallbackSecondary);
        SetBrush(app, "ArtworkFallbackTertiary", palette.ArtworkFallbackTertiary);
        SetBrush(app, "ArtworkHeroFallback", palette.ArtworkHeroFallback);
        SetColor(app, "HeroGradientStart", palette.HeroGradientStart);
        SetColor(app, "HeroGradientEnd", palette.HeroGradientEnd);

        SetColor(app, "SystemAccentColor", palette.NeutralAccent);
        SetColor(app, "SystemAccentColorLight1", palette.NeutralAccentLight1);
        SetColor(app, "SystemAccentColorLight2", palette.NeutralAccentLight2);
        SetColor(app, "SystemAccentColorLight3", palette.NeutralAccentLight3);
        SetColor(app, "SystemAccentColorDark1", palette.NeutralAccentDark1);
        SetColor(app, "SystemAccentColorDark2", palette.NeutralAccentDark2);
        SetColor(app, "SystemAccentColorDark3", palette.NeutralAccentDark3);

        SetBrush(app, "SliderTrackFill", palette.SliderTrackFill);
        SetBrush(app, "SliderTrackFillPointerOver", palette.SliderTrackFillPointerOver);
        SetBrush(app, "SliderTrackFillPressed", palette.SliderTrackFillPointerOver);
        SetBrush(app, "SliderTrackFillDisabled", palette.SliderTrackFillDisabled);
        SetBrush(app, "SliderTrackValueFill", palette.NeutralAccent);
        SetBrush(app, "SliderTrackValueFillPointerOver", palette.NeutralAccentLight1);
        SetBrush(app, "SliderTrackValueFillPressed", palette.NeutralAccentLight1);
        SetBrush(app, "SliderTrackValueFillDisabled", palette.NeutralAccentDark2);
        SetBrush(app, "SliderThumbBackground", palette.SliderThumbBackground);
        SetBrush(app, "SliderThumbBackgroundPointerOver", palette.SliderThumbBackground);
        SetBrush(app, "SliderThumbBackgroundPressed", palette.SliderThumbBackground);
        SetBrush(app, "SliderThumbBackgroundDisabled", palette.SliderThumbBackgroundDisabled);
    }

    private static void SetBrush(Application app, string key, string color) =>
        app.Resources[key] = new SolidColorBrush(Color.Parse(color));

    private static void SetColor(Application app, string key, string color) =>
        app.Resources[key] = Color.Parse(color);
}

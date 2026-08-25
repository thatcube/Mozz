namespace Mozz.Desktop.Core;

public enum MozzAppearance
{
    System,
    Light,
    Dark,
}

public enum MozzDarkStyle
{
    Dim,
    Black,
}

public enum MozzSystemTheme
{
    Light,
    Dark,
}

public enum MozzResolvedTheme
{
    Light,
    DarkDim,
    DarkBlack,
}

public sealed record MozzThemePalette(
    string Background,
    string Surface,
    string SurfaceRaised,
    string DetailBackground,
    string Brand,
    string BrandHover,
    string BrandPressed,
    string TextPrimary,
    string TextSecondary,
    string TextTertiary,
    string Divider,
    string SurfaceHover,
    string SurfaceSelected,
    string NeutralAccent,
    string NeutralAccentLight1,
    string NeutralAccentLight2,
    string NeutralAccentLight3,
    string NeutralAccentDark1,
    string NeutralAccentDark2,
    string NeutralAccentDark3,
    string SliderTrackFill,
    string SliderTrackFillPointerOver,
    string SliderTrackFillDisabled,
    string SliderThumbBackground,
    string SliderThumbBackgroundDisabled,
    string ArtworkFallbackPrimary,
    string ArtworkFallbackSecondary,
    string ArtworkFallbackTertiary,
    string ArtworkHeroFallback,
    string HeroGradientStart,
    string HeroGradientEnd)
{
    public string SidebarBackground => Surface;
    public string BarBackground => Surface;
    public string SearchBackground => SurfaceRaised;
}

public static class MozzTheme
{
    public const string AppearanceStorageKey = "mozz.appearance";
    public const string DarkStyleStorageKey = "mozz.darkStyle";
    public static readonly IReadOnlyList<(string From, string To)> ArtworkPlaceholderGradients =
    [
        ("#3A2C4E", "#241C33"),
        ("#2C3E4E", "#1C2833"),
        ("#4E3A2C", "#33241C"),
        ("#2C4E3E", "#1C3328"),
        ("#4E2C3A", "#331C24"),
        ("#3E4E2C", "#28331C"),
        ("#2C334E", "#1C2033"),
        ("#4E4A2C", "#33301C"),
    ];

    public static MozzAppearance ParseAppearance(string? value) => value switch
    {
        "light" => MozzAppearance.Light,
        "dark" => MozzAppearance.Dark,
        _ => MozzAppearance.System,
    };

    public static MozzDarkStyle ParseDarkStyle(string? value) => value == "black" ? MozzDarkStyle.Black : MozzDarkStyle.Dim;

    public static MozzResolvedTheme Resolve(MozzAppearance appearance, MozzDarkStyle darkStyle, MozzSystemTheme systemTheme)
    {
        var dark = appearance == MozzAppearance.Dark || (appearance == MozzAppearance.System && systemTheme == MozzSystemTheme.Dark);
        if (!dark) return MozzResolvedTheme.Light;
        return darkStyle == MozzDarkStyle.Black ? MozzResolvedTheme.DarkBlack : MozzResolvedTheme.DarkDim;
    }

    public static MozzThemePalette Palette(MozzAppearance appearance, MozzDarkStyle darkStyle, MozzSystemTheme systemTheme) =>
        Palette(Resolve(appearance, darkStyle, systemTheme));

    public static MozzThemePalette Palette(MozzResolvedTheme theme) => theme switch
    {
        MozzResolvedTheme.Light => new MozzThemePalette(
            Background: "#F2F2F7",
            Surface: "#FFFFFF",
            SurfaceRaised: "#FFFFFF",
            DetailBackground: "#121212",
            Brand: "#F50031",
            BrandHover: "#FF244E",
            BrandPressed: "#C80028",
            TextPrimary: "#000000",
            TextSecondary: "#993C3C43",
            TextTertiary: "#4D3C3C43",
            Divider: "#4A3C3C43",
            SurfaceHover: "#E5E5EA",
            SurfaceSelected: "#E5E5EA",
            NeutralAccent: "#8E8E93",
            NeutralAccentLight1: "#AEAEB2",
            NeutralAccentLight2: "#C7C7CC",
            NeutralAccentLight3: "#D1D1D6",
            NeutralAccentDark1: "#6C6C70",
            NeutralAccentDark2: "#545458",
            NeutralAccentDark3: "#3A3A3C",
            SliderTrackFill: "#D1D1D6",
            SliderTrackFillPointerOver: "#C7C7CC",
            SliderTrackFillDisabled: "#E5E5EA",
            SliderThumbBackground: "#FFFFFF",
            SliderThumbBackgroundDisabled: "#8E8E93",
            ArtworkFallbackPrimary: "#66FFFFFF",
            ArtworkFallbackSecondary: "#88FFFFFF",
            ArtworkFallbackTertiary: "#55FFFFFF",
            ArtworkHeroFallback: "#44FFFFFF",
            HeroGradientStart: "#00000000",
            HeroGradientEnd: "#CC000000"),
        MozzResolvedTheme.DarkDim => new MozzThemePalette(
            Background: "#1C1C1E",
            Surface: "#2C2C2E",
            SurfaceRaised: "#3A3A3C",
            DetailBackground: "#121212",
            Brand: "#F50031",
            BrandHover: "#FF244E",
            BrandPressed: "#C80028",
            TextPrimary: "#FFFFFF",
            TextSecondary: "#99EBEBF5",
            TextTertiary: "#4DEBEBF5",
            Divider: "#99545458",
            SurfaceHover: "#48484A",
            SurfaceSelected: "#3A3A3C",
            NeutralAccent: "#8E8E93",
            NeutralAccentLight1: "#AEAEB2",
            NeutralAccentLight2: "#C7C7CC",
            NeutralAccentLight3: "#D1D1D6",
            NeutralAccentDark1: "#6C6C70",
            NeutralAccentDark2: "#545458",
            NeutralAccentDark3: "#3A3A3C",
            SliderTrackFill: "#48484A",
            SliderTrackFillPointerOver: "#545458",
            SliderTrackFillDisabled: "#3A3A3C",
            SliderThumbBackground: "#FFFFFF",
            SliderThumbBackgroundDisabled: "#636366",
            ArtworkFallbackPrimary: "#66FFFFFF",
            ArtworkFallbackSecondary: "#88FFFFFF",
            ArtworkFallbackTertiary: "#55FFFFFF",
            ArtworkHeroFallback: "#44FFFFFF",
            HeroGradientStart: "#00000000",
            HeroGradientEnd: "#CC121212"),
        MozzResolvedTheme.DarkBlack => new MozzThemePalette(
            Background: "#000000",
            Surface: "#121212",
            SurfaceRaised: "#1C1C1E",
            DetailBackground: "#000000",
            Brand: "#F50031",
            BrandHover: "#FF244E",
            BrandPressed: "#C80028",
            TextPrimary: "#FFFFFF",
            TextSecondary: "#99EBEBF5",
            TextTertiary: "#4DEBEBF5",
            Divider: "#99545458",
            SurfaceHover: "#2C2C2E",
            SurfaceSelected: "#1C1C1E",
            NeutralAccent: "#8E8E93",
            NeutralAccentLight1: "#AEAEB2",
            NeutralAccentLight2: "#C7C7CC",
            NeutralAccentLight3: "#D1D1D6",
            NeutralAccentDark1: "#6C6C70",
            NeutralAccentDark2: "#545458",
            NeutralAccentDark3: "#3A3A3C",
            SliderTrackFill: "#2C2C2E",
            SliderTrackFillPointerOver: "#3A3A3C",
            SliderTrackFillDisabled: "#1C1C1E",
            SliderThumbBackground: "#FFFFFF",
            SliderThumbBackgroundDisabled: "#636366",
            ArtworkFallbackPrimary: "#66FFFFFF",
            ArtworkFallbackSecondary: "#88FFFFFF",
            ArtworkFallbackTertiary: "#55FFFFFF",
            ArtworkHeroFallback: "#44FFFFFF",
            HeroGradientStart: "#00000000",
            HeroGradientEnd: "#CC000000"),
        _ => throw new ArgumentOutOfRangeException(nameof(theme), theme, null),
    };
}

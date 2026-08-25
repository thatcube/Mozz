using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class ThemeTests
{
    public static TheoryData<MozzResolvedTheme, Dictionary<string, string>> Palettes => new()
    {
        { MozzResolvedTheme.Light, new Dictionary<string, string>
            {
                [nameof(MozzThemePalette.Background)] = "#F2F2F7",
                [nameof(MozzThemePalette.Surface)] = "#FFFFFF",
                [nameof(MozzThemePalette.SurfaceRaised)] = "#FFFFFF",
                [nameof(MozzThemePalette.DetailBackground)] = "#121212",
                [nameof(MozzThemePalette.Brand)] = "#F50031",
                [nameof(MozzThemePalette.BrandHover)] = "#FF244E",
                [nameof(MozzThemePalette.BrandPressed)] = "#C80028",
                [nameof(MozzThemePalette.TextPrimary)] = "#000000",
                [nameof(MozzThemePalette.TextSecondary)] = "#993C3C43",
                [nameof(MozzThemePalette.TextTertiary)] = "#4D3C3C43",
                [nameof(MozzThemePalette.Divider)] = "#4A3C3C43",
                [nameof(MozzThemePalette.SurfaceHover)] = "#E5E5EA",
                [nameof(MozzThemePalette.SurfaceSelected)] = "#E5E5EA",
                [nameof(MozzThemePalette.NeutralAccent)] = "#8E8E93",
                [nameof(MozzThemePalette.NeutralAccentLight1)] = "#AEAEB2",
                [nameof(MozzThemePalette.NeutralAccentLight2)] = "#C7C7CC",
                [nameof(MozzThemePalette.NeutralAccentLight3)] = "#D1D1D6",
                [nameof(MozzThemePalette.NeutralAccentDark1)] = "#6C6C70",
                [nameof(MozzThemePalette.NeutralAccentDark2)] = "#545458",
                [nameof(MozzThemePalette.NeutralAccentDark3)] = "#3A3A3C",
                [nameof(MozzThemePalette.SliderTrackFill)] = "#D1D1D6",
                [nameof(MozzThemePalette.SliderTrackFillPointerOver)] = "#C7C7CC",
                [nameof(MozzThemePalette.SliderTrackFillDisabled)] = "#E5E5EA",
                [nameof(MozzThemePalette.SliderThumbBackground)] = "#FFFFFF",
                [nameof(MozzThemePalette.SliderThumbBackgroundDisabled)] = "#8E8E93",
                [nameof(MozzThemePalette.ArtworkFallbackPrimary)] = "#66FFFFFF",
                [nameof(MozzThemePalette.ArtworkFallbackSecondary)] = "#88FFFFFF",
                [nameof(MozzThemePalette.ArtworkFallbackTertiary)] = "#55FFFFFF",
                [nameof(MozzThemePalette.ArtworkHeroFallback)] = "#44FFFFFF",
                [nameof(MozzThemePalette.HeroGradientStart)] = "#00000000",
                [nameof(MozzThemePalette.HeroGradientEnd)] = "#CC000000",
            }
        },
        { MozzResolvedTheme.DarkDim, new Dictionary<string, string>
            {
                [nameof(MozzThemePalette.Background)] = "#1C1C1E",
                [nameof(MozzThemePalette.Surface)] = "#2C2C2E",
                [nameof(MozzThemePalette.SurfaceRaised)] = "#3A3A3C",
                [nameof(MozzThemePalette.DetailBackground)] = "#121212",
                [nameof(MozzThemePalette.Brand)] = "#F50031",
                [nameof(MozzThemePalette.BrandHover)] = "#FF244E",
                [nameof(MozzThemePalette.BrandPressed)] = "#C80028",
                [nameof(MozzThemePalette.TextPrimary)] = "#FFFFFF",
                [nameof(MozzThemePalette.TextSecondary)] = "#99EBEBF5",
                [nameof(MozzThemePalette.TextTertiary)] = "#4DEBEBF5",
                [nameof(MozzThemePalette.Divider)] = "#99545458",
                [nameof(MozzThemePalette.SurfaceHover)] = "#48484A",
                [nameof(MozzThemePalette.SurfaceSelected)] = "#3A3A3C",
                [nameof(MozzThemePalette.NeutralAccent)] = "#8E8E93",
                [nameof(MozzThemePalette.NeutralAccentLight1)] = "#AEAEB2",
                [nameof(MozzThemePalette.NeutralAccentLight2)] = "#C7C7CC",
                [nameof(MozzThemePalette.NeutralAccentLight3)] = "#D1D1D6",
                [nameof(MozzThemePalette.NeutralAccentDark1)] = "#6C6C70",
                [nameof(MozzThemePalette.NeutralAccentDark2)] = "#545458",
                [nameof(MozzThemePalette.NeutralAccentDark3)] = "#3A3A3C",
                [nameof(MozzThemePalette.SliderTrackFill)] = "#48484A",
                [nameof(MozzThemePalette.SliderTrackFillPointerOver)] = "#545458",
                [nameof(MozzThemePalette.SliderTrackFillDisabled)] = "#3A3A3C",
                [nameof(MozzThemePalette.SliderThumbBackground)] = "#FFFFFF",
                [nameof(MozzThemePalette.SliderThumbBackgroundDisabled)] = "#636366",
                [nameof(MozzThemePalette.ArtworkFallbackPrimary)] = "#66FFFFFF",
                [nameof(MozzThemePalette.ArtworkFallbackSecondary)] = "#88FFFFFF",
                [nameof(MozzThemePalette.ArtworkFallbackTertiary)] = "#55FFFFFF",
                [nameof(MozzThemePalette.ArtworkHeroFallback)] = "#44FFFFFF",
                [nameof(MozzThemePalette.HeroGradientStart)] = "#00000000",
                [nameof(MozzThemePalette.HeroGradientEnd)] = "#CC121212",
            }
        },
        { MozzResolvedTheme.DarkBlack, new Dictionary<string, string>
            {
                [nameof(MozzThemePalette.Background)] = "#000000",
                [nameof(MozzThemePalette.Surface)] = "#121212",
                [nameof(MozzThemePalette.SurfaceRaised)] = "#1C1C1E",
                [nameof(MozzThemePalette.DetailBackground)] = "#000000",
                [nameof(MozzThemePalette.Brand)] = "#F50031",
                [nameof(MozzThemePalette.BrandHover)] = "#FF244E",
                [nameof(MozzThemePalette.BrandPressed)] = "#C80028",
                [nameof(MozzThemePalette.TextPrimary)] = "#FFFFFF",
                [nameof(MozzThemePalette.TextSecondary)] = "#99EBEBF5",
                [nameof(MozzThemePalette.TextTertiary)] = "#4DEBEBF5",
                [nameof(MozzThemePalette.Divider)] = "#99545458",
                [nameof(MozzThemePalette.SurfaceHover)] = "#2C2C2E",
                [nameof(MozzThemePalette.SurfaceSelected)] = "#1C1C1E",
                [nameof(MozzThemePalette.NeutralAccent)] = "#8E8E93",
                [nameof(MozzThemePalette.NeutralAccentLight1)] = "#AEAEB2",
                [nameof(MozzThemePalette.NeutralAccentLight2)] = "#C7C7CC",
                [nameof(MozzThemePalette.NeutralAccentLight3)] = "#D1D1D6",
                [nameof(MozzThemePalette.NeutralAccentDark1)] = "#6C6C70",
                [nameof(MozzThemePalette.NeutralAccentDark2)] = "#545458",
                [nameof(MozzThemePalette.NeutralAccentDark3)] = "#3A3A3C",
                [nameof(MozzThemePalette.SliderTrackFill)] = "#2C2C2E",
                [nameof(MozzThemePalette.SliderTrackFillPointerOver)] = "#3A3A3C",
                [nameof(MozzThemePalette.SliderTrackFillDisabled)] = "#1C1C1E",
                [nameof(MozzThemePalette.SliderThumbBackground)] = "#FFFFFF",
                [nameof(MozzThemePalette.SliderThumbBackgroundDisabled)] = "#636366",
                [nameof(MozzThemePalette.ArtworkFallbackPrimary)] = "#66FFFFFF",
                [nameof(MozzThemePalette.ArtworkFallbackSecondary)] = "#88FFFFFF",
                [nameof(MozzThemePalette.ArtworkFallbackTertiary)] = "#55FFFFFF",
                [nameof(MozzThemePalette.ArtworkHeroFallback)] = "#44FFFFFF",
                [nameof(MozzThemePalette.HeroGradientStart)] = "#00000000",
                [nameof(MozzThemePalette.HeroGradientEnd)] = "#CC000000",
            }
        },
    };

    [Theory]
    [MemberData(nameof(Palettes))]
    public void EveryTokenResolvesForEveryTheme(MozzResolvedTheme theme, Dictionary<string, string> expected)
    {
        var palette = MozzTheme.Palette(theme);
        foreach (var (property, value) in expected)
        {
            var actual = typeof(MozzThemePalette).GetProperty(property)?.GetValue(palette);
            Assert.Equal(value, actual);
        }

        Assert.Equal(palette.Surface, palette.SidebarBackground);
        Assert.Equal(palette.Surface, palette.BarBackground);
        Assert.Equal(palette.SurfaceRaised, palette.SearchBackground);
    }

    [Fact]
    public void SystemAppearanceFollowsTheOsTheme()
    {
        Assert.Equal(MozzResolvedTheme.Light,
            MozzTheme.Resolve(MozzAppearance.System, MozzDarkStyle.Dim, MozzSystemTheme.Light));
        Assert.Equal(MozzResolvedTheme.DarkDim,
            MozzTheme.Resolve(MozzAppearance.System, MozzDarkStyle.Dim, MozzSystemTheme.Dark));
    }

    [Fact]
    public void OledStyleOnlyAppliesWhenDarkIsActive()
    {
        Assert.Equal(MozzResolvedTheme.Light,
            MozzTheme.Resolve(MozzAppearance.Light, MozzDarkStyle.Black, MozzSystemTheme.Dark));
        Assert.Equal(MozzResolvedTheme.Light,
            MozzTheme.Resolve(MozzAppearance.System, MozzDarkStyle.Black, MozzSystemTheme.Light));
        Assert.Equal(MozzResolvedTheme.DarkBlack,
            MozzTheme.Resolve(MozzAppearance.System, MozzDarkStyle.Black, MozzSystemTheme.Dark));
        Assert.Equal(MozzResolvedTheme.DarkBlack,
            MozzTheme.Resolve(MozzAppearance.Dark, MozzDarkStyle.Black, MozzSystemTheme.Light));
    }

    [Fact]
    public void DesktopUsesIosPreferenceKeys()
    {
        Assert.Equal(AppPreferences.AppearanceKey, MozzTheme.AppearanceStorageKey);
        Assert.Equal(AppPreferences.DarkStyleKey, MozzTheme.DarkStyleStorageKey);
    }
}

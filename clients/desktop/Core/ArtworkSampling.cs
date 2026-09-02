using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.Immutable;
using Avalonia.Platform;

namespace Mozz.Desktop.Core;

/// <summary>
/// Reduce a cover to the pixels the core wants to see, and turn what it sends
/// back into a brush.
///
/// The scoring — which colours a record is "about", how far to pull the accents
/// toward the dominant tone, how bright the result may get before white text
/// stops being legible — lives in <c>MozzCore.ArtworkPalette</c> and is reached
/// through the <c>artworkTones</c> FFI command. That is deliberate and is the
/// whole reason this file is so small: iOS, Android and the desktop must not
/// drift apart on what an album looks like, and three clients each guessing at
/// "colours from the artwork" would drift apart immediately. What stays here is
/// the part that genuinely cannot be shared — Avalonia decodes its own images.
///
/// The sibling implementations are <c>ArtworkSampling</c> in Android's
/// <c>PlayerBackground.kt</c> and <c>ArtworkPalette.grid</c> in the iOS
/// <c>PlayerBackground.swift</c>. The constants below are theirs.
/// </summary>
public static class ArtworkSampling
{
    /// <summary>48×48 ≈ 2.3k pixels — plenty to characterise a cover, cheap to scale.</summary>
    public const int SampleDim = 48;

    /// <summary>Small on purpose: this image is histogrammed, never shown.</summary>
    public const int RequestSize = 240;

    /// <summary>
    /// Scale a cover to the sample grid and hand back tightly packed RGBA, which
    /// is the layout the core reads.
    ///
    /// Avalonia renders to BGRA, so the two colour channels are swapped on the
    /// way out. Getting that backwards does not fail — it produces a plausible
    /// backdrop in the wrong colour — so it is worth being explicit about.
    /// </summary>
    public static byte[]? Rgba(Bitmap bitmap)
    {
        try
        {
            using var target = new RenderTargetBitmap(new PixelSize(SampleDim, SampleDim));
            using (var context = target.CreateDrawingContext())
            {
                context.DrawImage(
                    bitmap,
                    new Rect(bitmap.Size),
                    new Rect(0, 0, SampleDim, SampleDim));
            }

            var stride = SampleDim * 4;
            var bytes = new byte[stride * SampleDim];
            unsafe
            {
                fixed (byte* buffer = bytes)
                {
                    target.CopyPixels(
                        new PixelRect(0, 0, SampleDim, SampleDim),
                        (nint)buffer, bytes.Length, stride);
                }
            }

            for (var i = 0; i < bytes.Length; i += 4)
                (bytes[i], bytes[i + 2]) = (bytes[i + 2], bytes[i]);

            return bytes;
        }
        catch
        {
            // A cover we cannot rasterise is not an error worth surfacing; the
            // player falls back to its plain field.
            return null;
        }
    }

    /// <summary>
    /// The backdrop as a vertical three-stop gradient.
    ///
    /// iOS paints these tones as a 3×3 <c>MeshGradient</c> and Android as a
    /// drifting canvas, and neither has an equivalent here — but the iOS grid is
    /// row-uniform (each row is one tone), so a vertical gradient reproduces the
    /// same field. What the desktop does not reproduce is the slow drift: that is
    /// called out in the iOS source as the genuinely per-platform half, it needs
    /// a full-window repaint every frame, and the tones are what carry the
    /// record's identity. The colours match; the motion does not exist.
    /// </summary>
    public static IBrush Brush(ArtworkTones tones) =>
        new ImmutableLinearGradientBrush(
            [
                new ImmutableGradientStop(0, ToColor(tones.Top)),
                new ImmutableGradientStop(0.5, ToColor(tones.Middle)),
                new ImmutableGradientStop(1, ToColor(tones.Bottom)),
            ],
            startPoint: new RelativePoint(0, 0, RelativeUnit.Relative),
            endPoint: new RelativePoint(0, 1, RelativeUnit.Relative));

    private static Color ToColor(ArtworkTone tone) => Color.FromRgb(
        Channel(tone.Red), Channel(tone.Green), Channel(tone.Blue));

    private static byte Channel(double value) =>
        (byte)Math.Clamp(Math.Round(value * 255), 0, 255);
}

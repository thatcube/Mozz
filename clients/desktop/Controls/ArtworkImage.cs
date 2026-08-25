using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.Controls;

/// <summary>
/// A cover that shows real artwork once it has loaded and a coloured placeholder
/// until then — the one place the app turns an <c>ArtworkKey</c> into pixels.
///
/// It replaces the hand-rolled <c>Border</c>-plus-letter that every grid tile,
/// song row and the player bar used to draw. Folding the whole story into a
/// control keeps the model records pure — they stay immutable things decoded from
/// JSON, with no bitmap or loading flag bolted on — and, more importantly, puts
/// the recycling-safe loading in exactly one place. Because these tiles are
/// virtualized their containers are reused as the wall scrolls, and the
/// <see cref="ArtworkBinder{T}"/> this holds is what ensures a cover that finishes
/// downloading after its tile has been reused for another album is discarded
/// rather than painted onto the wrong record.
///
/// It renders directly rather than through a template so there is no second visual
/// tree per tile to realize — there can be tens of thousands of these — and it
/// reuses <see cref="ArtworkPlaceholderConverter"/> and <see cref="InitialConverter"/>
/// for the fallback so an un-loaded cover looks exactly as it did before real art
/// arrived.
/// </summary>
public sealed class ArtworkImage : Control
{
    // Desktop displays are near-universally 2x; asking the server for twice the
    // drawn size keeps covers crisp on retina without requesting a needlessly
    // large image to shrink — the waste the fixed 512 used to be.
    private const double RetinaScale = 2.0;

    private static readonly FontFamily InterFont =
        new("avares://Avalonia.Fonts.Inter/Assets#Inter");

    public static readonly StyledProperty<string?> ServerIdProperty =
        AvaloniaProperty.Register<ArtworkImage, string?>(nameof(ServerId));

    public static readonly StyledProperty<string?> ArtworkKeyProperty =
        AvaloniaProperty.Register<ArtworkImage, string?>(nameof(ArtworkKey));

    /// <summary>The drawn size in DIPs; also what the cover is requested at (×2).</summary>
    public static readonly StyledProperty<double> DisplaySizeProperty =
        AvaloniaProperty.Register<ArtworkImage, double>(nameof(DisplaySize), 48);

    public static readonly StyledProperty<CornerRadius> CornerRadiusProperty =
        AvaloniaProperty.Register<ArtworkImage, CornerRadius>(nameof(CornerRadius));

    public static readonly StyledProperty<string?> FallbackTextProperty =
        AvaloniaProperty.Register<ArtworkImage, string?>(nameof(FallbackText));

    public static readonly StyledProperty<double> FallbackFontSizeProperty =
        AvaloniaProperty.Register<ArtworkImage, double>(nameof(FallbackFontSize), 20);

    public static readonly StyledProperty<FontWeight> FallbackFontWeightProperty =
        AvaloniaProperty.Register<ArtworkImage, FontWeight>(nameof(FallbackFontWeight), FontWeight.Bold);

    public static readonly StyledProperty<IBrush?> FallbackForegroundProperty =
        AvaloniaProperty.Register<ArtworkImage, IBrush?>(
            nameof(FallbackForeground),
            new SolidColorBrush(Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF)));

    public static readonly StyledProperty<bool> ArtistHeroProperty =
        AvaloniaProperty.Register<ArtworkImage, bool>(nameof(ArtistHero));

    static ArtworkImage()
    {
        AffectsRender<ArtworkImage>(
            FallbackTextProperty, FallbackFontSizeProperty, FallbackFontWeightProperty,
            FallbackForegroundProperty, CornerRadiusProperty, ArtistHeroProperty);
        AffectsMeasure<ArtworkImage>(DisplaySizeProperty);
    }

    private ArtworkBinder<Bitmap>? _binder;
    private ArtworkRef? _boundRequest;
    private bool _hasBound;
    private Bitmap? _bitmap;

    public string? ServerId { get => GetValue(ServerIdProperty); set => SetValue(ServerIdProperty, value); }
    public string? ArtworkKey { get => GetValue(ArtworkKeyProperty); set => SetValue(ArtworkKeyProperty, value); }
    public double DisplaySize { get => GetValue(DisplaySizeProperty); set => SetValue(DisplaySizeProperty, value); }
    public CornerRadius CornerRadius { get => GetValue(CornerRadiusProperty); set => SetValue(CornerRadiusProperty, value); }
    public string? FallbackText { get => GetValue(FallbackTextProperty); set => SetValue(FallbackTextProperty, value); }
    public double FallbackFontSize { get => GetValue(FallbackFontSizeProperty); set => SetValue(FallbackFontSizeProperty, value); }
    public FontWeight FallbackFontWeight { get => GetValue(FallbackFontWeightProperty); set => SetValue(FallbackFontWeightProperty, value); }
    public IBrush? FallbackForeground { get => GetValue(FallbackForegroundProperty); set => SetValue(FallbackForegroundProperty, value); }
    public bool ArtistHero { get => GetValue(ArtistHeroProperty); set => SetValue(ArtistHeroProperty, value); }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == ServerIdProperty ||
            change.Property == ArtworkKeyProperty ||
            change.Property == DisplaySizeProperty)
        {
            Rebind();
        }
    }

    private void Rebind()
    {
        var request = BuildRequest();

        // The recycling churn of virtualization sets these properties repeatedly,
        // often to the same values; only a genuine change should disturb a load.
        if (_hasBound && Nullable.Equals(request, _boundRequest)) return;
        _boundRequest = request;
        _hasBound = true;

        EnsureBinder().Bind(request);
    }

    private ArtworkRef? BuildRequest()
    {
        var server = ServerId;
        var key = ArtworkKey;
        if (string.IsNullOrEmpty(server) || string.IsNullOrEmpty(key)) return null;

        var pixels = (int)Math.Ceiling(Math.Max(1, DisplaySize) * RetinaScale);
        return new ArtworkRef(server, key, pixels);
    }

    private ArtworkBinder<Bitmap> EnsureBinder()
        => _binder ??= new ArtworkBinder<Bitmap>(
            load: static (request, token) =>
                ArtworkService.Current?.LoadAsync(request, token)
                ?? Task.FromResult<Bitmap?>(null),
            apply: bitmap =>
            {
                _bitmap = bitmap;
                InvalidateVisual();
            },
            post: action => Dispatcher.UIThread.Post(action));

    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        if (bounds.Width <= 0 || bounds.Height <= 0) return;

        var radius = Math.Max(0, CornerRadius.TopLeft);
        var rounded = new RoundedRect(bounds, radius);

        var bitmap = _bitmap;
        if (bitmap is not null)
        {
            if (ArtistHero && ArtworkPresentation.ShouldUseCircularArtistPortrait(bitmap.Size.Width, bitmap.Size.Height))
            {
                DrawFallback(context, bounds, rounded);
                var side = Math.Min(bounds.Width, bounds.Height) * 0.78;
                side = Math.Clamp(side, 132, Math.Min(220, Math.Min(bounds.Width, bounds.Height)));
                var target = new Rect((bounds.Width - side) / 2, (bounds.Height - side) / 2, side, side);
                using (context.PushClip(new RoundedRect(target, side / 2)))
                {
                    context.DrawImage(bitmap, CropRect(bitmap.Size, target.Size), target);
                }
                return;
            }

            using (context.PushClip(rounded))
            {
                context.DrawImage(bitmap, CropRect(bitmap.Size, bounds.Size), bounds);
            }
            return;
        }

        DrawFallback(context, bounds, rounded);
    }

    private void DrawFallback(DrawingContext context, Rect bounds, RoundedRect rounded)
    {
        var culture = CultureInfo.CurrentCulture;

        if (ArtworkPlaceholderConverter.Instance.Convert(FallbackText, typeof(IBrush), null, culture)
            is IBrush brush)
        {
            context.DrawRectangle(brush, null, rounded);
        }

        if (FallbackFontSize <= 0) return;
        if (InitialConverter.Instance.Convert(FallbackText, typeof(string), null, culture)
            is not string letter || string.IsNullOrEmpty(letter))
        {
            return;
        }

        var typeface = new Typeface(InterFont, FontStyle.Normal, FallbackFontWeight);
        var text = new FormattedText(
            letter, culture, FlowDirection.LeftToRight, typeface, FallbackFontSize,
            FallbackForeground ?? Brushes.White);

        var origin = new Point(
            (bounds.Width - text.Width) / 2,
            (bounds.Height - text.Height) / 2);
        context.DrawText(text, origin);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var size = DisplaySize > 0 ? DisplaySize : 0;
        return new Size(size, size);
    }

    private static Rect CropRect(Size source, Size destination)
    {
        var crop = ArtworkPresentation.CoverCrop(source.Width, source.Height, destination.Width, destination.Height);
        return new Rect(crop.X, crop.Y, crop.Width, crop.Height);
    }
}

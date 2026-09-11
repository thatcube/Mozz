using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Mozz.Desktop.ViewModels;

namespace Mozz.Desktop.Controls;

/// <summary>
/// Five stars, set by clicking one or by dragging across them.
///
/// The desktop had neither. Its player was five separate buttons hard-wired to
/// the whole numbers one to five, so a library that stores half stars — which
/// Plex does, and which the core clamps to 0.5–5.0 — could not express half of
/// its own values from the control built to set them. The row menu could, but
/// only as a list of typed-out glyphs ("★★½"), which is a spelling of a rating
/// rather than a picture of one.
///
/// This is the iPhone's control, which is the one worth copying: one gesture
/// handles both a tap and a slide, the stars light as the pointer crosses them,
/// and dragging left off the first star clears. The desktop adds one thing the
/// phone cannot — a pointer can hover without pressing, so moving over the strip
/// previews what a click would set, and leaving without clicking puts it back.
/// </summary>
public sealed class RatingStrip : Control
{
    public static readonly StyledProperty<double?> ValueProperty =
        AvaloniaProperty.Register<RatingStrip, double?>(nameof(Value));

    public static readonly StyledProperty<double> StarSizeProperty =
        AvaloniaProperty.Register<RatingStrip, double>(nameof(StarSize), RatingMath.StarSize);

    public static readonly StyledProperty<double> SpacingProperty =
        AvaloniaProperty.Register<RatingStrip, double>(nameof(Spacing), RatingMath.Spacing);

    public static readonly StyledProperty<bool> IsInteractiveProperty =
        AvaloniaProperty.Register<RatingStrip, bool>(nameof(IsInteractive), true);

    public static readonly StyledProperty<IBrush?> FilledBrushProperty =
        AvaloniaProperty.Register<RatingStrip, IBrush?>(nameof(FilledBrush));

    public static readonly StyledProperty<IBrush?> EmptyBrushProperty =
        AvaloniaProperty.Register<RatingStrip, IBrush?>(nameof(EmptyBrush));

    /// <summary>Raised on release with the rating the pointer landed on; null clears.</summary>
    public event EventHandler<double?>? Committed;

    /// <summary>
    /// Raised as the pointer crosses the strip, with what a click would set —
    /// and again with <see cref="Value"/> when it leaves without clicking.
    ///
    /// For anything drawn beside the stars that has to agree with them. A
    /// readout that keeps showing the committed value while the stars preview a
    /// different one is the strip contradicting itself in words.
    /// </summary>
    public event EventHandler<double?>? Previewed;

    /// <summary>
    /// What the strip is currently showing: the previewed value while the
    /// pointer is over it, and <see cref="Value"/> otherwise.
    /// </summary>
    private double? _preview;
    private bool _previewing;
    private bool _dragging;

    static RatingStrip()
    {
        AffectsRender<RatingStrip>(ValueProperty, StarSizeProperty, SpacingProperty,
            FilledBrushProperty, EmptyBrushProperty);
        AffectsMeasure<RatingStrip>(StarSizeProperty, SpacingProperty);
        FocusableProperty.OverrideDefaultValue<RatingStrip>(true);
    }

    public double? Value
    {
        get => GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
    }

    public double StarSize
    {
        get => GetValue(StarSizeProperty);
        set => SetValue(StarSizeProperty, value);
    }

    public double Spacing
    {
        get => GetValue(SpacingProperty);
        set => SetValue(SpacingProperty, value);
    }

    public bool IsInteractive
    {
        get => GetValue(IsInteractiveProperty);
        set => SetValue(IsInteractiveProperty, value);
    }

    public IBrush? FilledBrush
    {
        get => GetValue(FilledBrushProperty);
        set => SetValue(FilledBrushProperty, value);
    }

    public IBrush? EmptyBrush
    {
        get => GetValue(EmptyBrushProperty);
        set => SetValue(EmptyBrushProperty, value);
    }

    private double? Shown => _previewing ? _preview : Value;

    protected override Size MeasureOverride(Size availableSize)
    {
        // Taller than the glyphs so the strip meets a sane pointer target
        // without enlarging the stars. The hit math reads X only, so the extra
        // height is free.
        return new Size(RatingMath.StripWidth(StarSize, Spacing), Math.Max(StarSize, 28));
    }

    public override void Render(DrawingContext context)
    {
        // A transparent fill across the whole control, first, because Avalonia
        // hit-tests what was painted: a bare Control that only draws glyphs has
        // gaps between them and nothing at all in the padding, so the pointer
        // fell straight through and neither the hover preview nor a click ever
        // arrived. Same reason a Border needs Background="Transparent" to be
        // clickable.
        context.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));

        var shown = Shown ?? 0;
        var filled = FilledBrush ?? Brushes.Gold;
        var empty = EmptyBrush ?? Brushes.Gray;
        var y = (Bounds.Height - StarSize) / 2;

        for (var i = 0; i < RatingMath.StarCount; i++)
        {
            var x = i * (StarSize + Spacing);
            var held = shown - i;
            var key = held >= 1.0 ? "IconStarFilled"
                : held >= 0.5 ? "IconStarHalf"
                : "IconStar";
            // A star holding at least a half is drawn in the accent; the empties
            // stay quiet, so the filled run is what the eye counts.
            DrawStar(context, key, x, y, held >= 0.5 ? filled : empty, held >= 0.5);
        }
    }

    private void DrawStar(DrawingContext context, string key, double x, double y, IBrush brush, bool solid)
    {
        if (Application.Current?.TryFindResource(key, out var value) != true) return;
        if (value is not Geometry geometry) return;

        var scale = StarSize / 24.0;
        using var _ = context.PushTransform(Matrix.CreateScale(scale, scale) * Matrix.CreateTranslation(x, y));
        if (solid)
        {
            context.DrawGeometry(brush, null, geometry);
        }
        else
        {
            // Tabler's outline star is a stroke glyph; at the canonical weight of
            // two grid units it matches every other icon on screen.
            context.DrawGeometry(null, new Pen(brush, 2, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round), geometry);
        }
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (!IsInteractive) return;
        Show(RatingMath.RatingAtX(e.GetPosition(this).X, StarSize, Spacing));
    }

    protected override void OnPointerEntered(PointerEventArgs e)
    {
        base.OnPointerEntered(e);
        if (!IsInteractive) return;
        Show(RatingMath.RatingAtX(e.GetPosition(this).X, StarSize, Spacing));
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        // A drag that leaves the strip is still a drag: the pointer is captured,
        // and letting go outside is how the phone clears a rating. Only an
        // un-pressed pointer leaving puts the real value back.
        if (_dragging) return;
        _previewing = false;
        Previewed?.Invoke(this, Value);
        InvalidateVisual();
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (!IsInteractive) return;
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        _dragging = true;
        e.Pointer.Capture(this);
        Show(RatingMath.RatingAtX(e.GetPosition(this).X, StarSize, Spacing));
        // Claimed so a strip living inside a menu item does not also count as a
        // click on the item, which would dismiss the menu on the first half star.
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (!_dragging) return;
        _dragging = false;
        e.Pointer.Capture(null);

        var picked = RatingMath.RatingAtX(e.GetPosition(this).X, StarSize, Spacing);
        Value = picked;
        _previewing = false;
        Committed?.Invoke(this, picked);
        InvalidateVisual();
        e.Handled = true;
    }

    private void Show(double? value)
    {
        if (_previewing && _preview == value) return;
        _preview = value;
        _previewing = true;
        Previewed?.Invoke(this, value);
        InvalidateVisual();
    }
}

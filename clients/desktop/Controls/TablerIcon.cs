using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Mozz.Desktop.Controls;

/// <summary>
/// Draws a single Tabler icon geometry normalised to Tabler's native 24×24 grid.
///
/// The reason this is a hand-drawn control rather than a <see cref="Avalonia.Controls.Shape"/>/
/// <c>Path</c> with <c>Stretch</c> is consistency. Avalonia's shapes scale a path
/// to its <em>tight</em> geometry bounds, so a wide glyph (the queue lines) and a
/// tall one (a skip triangle) would each get a different scale factor — and, because
/// the stroke scales with the path, a different on-screen stroke weight and a
/// different amount of optical padding. A dock full of transport buttons drawn that
/// way reads as a jumble, which is exactly the "unstyled" look we're replacing.
///
/// Instead every icon is drawn on the same 24-unit canvas scaled by
/// <see cref="Size"/>/24, so glyphs share one optical size and one padding, and a
/// stroke authored at Tabler's canonical width of 2 units renders at an identical
/// weight across every icon at a given <see cref="Size"/>. Stroke glyphs get round
/// caps and joins to match Tabler; the handful of solid glyphs (play, pause, the
/// skip arrows) set <see cref="Filled"/> and are filled instead.
///
/// The icon inherits its colour from <see cref="Brush"/>, which callers bind to the
/// hosting button's foreground so the existing hover/selected style setters keep
/// driving the colour without this control knowing anything about them.
/// </summary>
public sealed class TablerIcon : Control
{
    /// <summary>Tabler's design grid; every geometry key in Icons.axaml is authored on it.</summary>
    private const double Grid = 24.0;

    public static readonly StyledProperty<Geometry?> DataProperty =
        AvaloniaProperty.Register<TablerIcon, Geometry?>(nameof(Data));

    public static readonly StyledProperty<double> SizeProperty =
        AvaloniaProperty.Register<TablerIcon, double>(nameof(Size), 20.0);

    public static readonly StyledProperty<IBrush?> BrushProperty =
        AvaloniaProperty.Register<TablerIcon, IBrush?>(nameof(Brush), Brushes.White);

    public static readonly StyledProperty<bool> FilledProperty =
        AvaloniaProperty.Register<TablerIcon, bool>(nameof(Filled));

    /// <summary>Stroke width in grid units; 2 is Tabler's canonical weight.</summary>
    public static readonly StyledProperty<double> StrokeThicknessProperty =
        AvaloniaProperty.Register<TablerIcon, double>(nameof(StrokeThickness), 2.0);

    static TablerIcon()
    {
        AffectsRender<TablerIcon>(DataProperty, BrushProperty, FilledProperty, StrokeThicknessProperty, SizeProperty);
        AffectsMeasure<TablerIcon>(SizeProperty);
    }

    public Geometry? Data
    {
        get => GetValue(DataProperty);
        set => SetValue(DataProperty, value);
    }

    public double Size
    {
        get => GetValue(SizeProperty);
        set => SetValue(SizeProperty, value);
    }

    public IBrush? Brush
    {
        get => GetValue(BrushProperty);
        set => SetValue(BrushProperty, value);
    }

    public bool Filled
    {
        get => GetValue(FilledProperty);
        set => SetValue(FilledProperty, value);
    }

    public double StrokeThickness
    {
        get => GetValue(StrokeThicknessProperty);
        set => SetValue(StrokeThicknessProperty, value);
    }

    protected override Size MeasureOverride(Size availableSize) => new(Size, Size);

    public override void Render(DrawingContext context)
    {
        var geometry = Data;
        if (geometry is null || Size <= 0)
            return;

        var brush = Brush;
        if (brush is null)
            return;

        var scale = Size / Grid;
        using (context.PushTransform(Matrix.CreateScale(scale, scale)))
        {
            if (Filled)
            {
                context.DrawGeometry(brush, null, geometry);
            }
            else
            {
                var pen = new Pen(brush, StrokeThickness, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
                context.DrawGeometry(null, pen, geometry);
            }
        }
    }
}

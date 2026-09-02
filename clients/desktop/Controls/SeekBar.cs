using System.Globalization;
using System.Windows.Input;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.LogicalTree;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Threading;

namespace Mozz.Desktop.Controls;

/// <summary>
/// The transport scrubber: a knob-less capsule that fills to the current
/// position, with the elapsed time on the left, the remaining time on the right,
/// and the audio format centred between them.
///
/// This is a port of the iPhone's <c>SeekBar.swift</c>, and it exists because
/// Fluent's <see cref="Slider"/> could not be made to look like it. The stock
/// template is a track plus a thumb, and a thumb is precisely what this design
/// does not have: at rest the bar is a quiet 6px rule, and the only feedback is
/// that it grows and brightens while you are working it. Restyling the slider
/// got as far as hiding the thumb and left the rest — the 50px measured height,
/// the hover plate, the discrete tick behaviour — fighting the design.
///
/// Two independent activations drive every animated value, so hover and drag
/// feel like different states rather than one on/off switch:
/// <list type="bullet">
///   <item><description><see cref="BarActivation"/> rises on hover <em>or</em>
///   drag and drives the bar's height and the rail's opacity. Growing under the
///   pointer is the desktop half of this control — the phone has nothing to
///   hover with, so it grows on touch instead.</description></item>
///   <item><description><see cref="LabelActivation"/> rises only while
///   dragging and drives the time labels' opacity, weight and scale, matching
///   what the phone does on press.</description></item>
/// </list>
/// Both are real styled properties with transitions rather than hand-rolled
/// timers, so the interpolation and easing are the framework's.
///
/// Seeking is a two-phase gesture, again as on iOS. While dragging, the bar
/// paints a local scrub value and the player is left alone. On release it fires
/// <see cref="SeekCommand"/> once and keeps painting the released target until
/// the player's own position catches up (or <see cref="SettleTimeout"/> passes),
/// because handing the display straight back to <see cref="Position"/> shows its
/// stale pre-seek value for up to one tick and makes the fill spring away and
/// back.
///
/// With <see cref="IsContinuous"/> set the settle machinery is bypassed and the
/// drag writes <see cref="Position"/> live — what the volume bar wants, where
/// there is no round trip to wait for.
/// </summary>
public sealed class SeekBar : Control
{
    // MARK: Tunables — the phone's values, in device-independent pixels.

    private const double RestTrackOpacity = 0.30;
    private const double ActiveTrackOpacity = 0.42;
    private const double RestFillOpacity = 0.82;
    private const double ActiveFillOpacity = 1.0;
    private const double RestLabelOpacity = 0.5;
    private const double ActiveLabelOpacity = 1.0;
    private const double ScrubLabelScale = 1.14;

    /// <summary>How far outside the bar the pointer still counts as on it.</summary>
    private const double HitSlop = 5.0;

    /// <summary>Within this many seconds, the player has caught up with the seek.</summary>
    private const double SettleTolerance = 1.0;

    private static readonly TimeSpan SettleTimeout = TimeSpan.FromSeconds(2);

    private static readonly FontFamily InterFont =
        new("avares://Avalonia.Fonts.Inter/Assets#Inter");

    public static readonly StyledProperty<double> PositionProperty =
        AvaloniaProperty.Register<SeekBar, double>(
            nameof(Position), defaultBindingMode: Avalonia.Data.BindingMode.TwoWay);

    public static readonly StyledProperty<double> DurationProperty =
        AvaloniaProperty.Register<SeekBar, double>(nameof(Duration));

    /// <summary>
    /// Identity of what is playing. Changing it clears any in-flight scrub or
    /// settle, so a track that changes under the pointer does not leave the bar
    /// painting the previous song's position.
    /// </summary>
    public static readonly StyledProperty<string?> TrackKeyProperty =
        AvaloniaProperty.Register<SeekBar, string?>(nameof(TrackKey));

    /// <summary>Codec badge — "FLAC", "AAC" — or null to draw none.</summary>
    public static readonly StyledProperty<string?> FormatLabelProperty =
        AvaloniaProperty.Register<SeekBar, string?>(nameof(FormatLabel));

    public static readonly StyledProperty<ICommand?> SeekCommandProperty =
        AvaloniaProperty.Register<SeekBar, ICommand?>(nameof(SeekCommand));

    /// <summary>The colour everything is drawn in, at varying opacity. Bind to TextPrimary.</summary>
    public static readonly StyledProperty<IBrush?> TintProperty =
        AvaloniaProperty.Register<SeekBar, IBrush?>(nameof(Tint), Brushes.White);

    public static readonly StyledProperty<double> RestHeightProperty =
        AvaloniaProperty.Register<SeekBar, double>(nameof(RestHeight), 6.0);

    public static readonly StyledProperty<double> ActiveHeightProperty =
        AvaloniaProperty.Register<SeekBar, double>(nameof(ActiveHeight), 12.0);

    public static readonly StyledProperty<bool> ShowLabelsProperty =
        AvaloniaProperty.Register<SeekBar, bool>(nameof(ShowLabels), true);

    /// <summary>Drag writes <see cref="Position"/> live and no seek is fired. For volume.</summary>
    public static readonly StyledProperty<bool> IsContinuousProperty =
        AvaloniaProperty.Register<SeekBar, bool>(nameof(IsContinuous));

    public static readonly StyledProperty<double> LabelFontSizeProperty =
        AvaloniaProperty.Register<SeekBar, double>(nameof(LabelFontSize), 11.0);

    public static readonly StyledProperty<double> LabelSpacingProperty =
        AvaloniaProperty.Register<SeekBar, double>(nameof(LabelSpacing), 8.0);

    /// <summary>How far one arrow-key press moves the position, in seconds.</summary>
    public static readonly StyledProperty<double> KeyboardStepProperty =
        AvaloniaProperty.Register<SeekBar, double>(nameof(KeyboardStep), 5.0);

    /// <summary>0 at rest, 1 while hovered or dragged. Animated; drives height and rail.</summary>
    public static readonly StyledProperty<double> BarActivationProperty =
        AvaloniaProperty.Register<SeekBar, double>(nameof(BarActivation));

    /// <summary>0 at rest, 1 while dragging. Animated; drives the labels.</summary>
    public static readonly StyledProperty<double> LabelActivationProperty =
        AvaloniaProperty.Register<SeekBar, double>(nameof(LabelActivation));

    private bool _dragging;
    private bool _hovering;
    private double _scrubValue;
    private double? _settlingValue;
    private DispatcherTimer? _settleTimer;

    static SeekBar()
    {
        AffectsRender<SeekBar>(
            PositionProperty, DurationProperty, FormatLabelProperty, TintProperty,
            RestHeightProperty, ActiveHeightProperty, ShowLabelsProperty,
            LabelFontSizeProperty, BarActivationProperty, LabelActivationProperty);
        AffectsMeasure<SeekBar>(
            ActiveHeightProperty, ShowLabelsProperty, LabelFontSizeProperty, LabelSpacingProperty);
        FocusableProperty.OverrideDefaultValue<SeekBar>(true);
    }

    public SeekBar()
    {
        Cursor = new Cursor(StandardCursorType.Hand);
        // 0.34s is the phone's `.smooth` duration; the easing is the closest
        // stock curve to it. Doing this with transitions rather than a timer
        // means the two activations interpolate independently and correctly
        // even when hover and drag start or end on the same frame.
        Transitions =
        [
            new DoubleTransition
            {
                Property = BarActivationProperty,
                Duration = TimeSpan.FromMilliseconds(340),
                Easing = new CubicEaseOut(),
            },
            new DoubleTransition
            {
                Property = LabelActivationProperty,
                Duration = TimeSpan.FromMilliseconds(340),
                Easing = new CubicEaseOut(),
            },
        ];
    }

    public double Position
    {
        get => GetValue(PositionProperty);
        set => SetValue(PositionProperty, value);
    }

    public double Duration
    {
        get => GetValue(DurationProperty);
        set => SetValue(DurationProperty, value);
    }

    public string? TrackKey
    {
        get => GetValue(TrackKeyProperty);
        set => SetValue(TrackKeyProperty, value);
    }

    public string? FormatLabel
    {
        get => GetValue(FormatLabelProperty);
        set => SetValue(FormatLabelProperty, value);
    }

    public ICommand? SeekCommand
    {
        get => GetValue(SeekCommandProperty);
        set => SetValue(SeekCommandProperty, value);
    }

    public IBrush? Tint
    {
        get => GetValue(TintProperty);
        set => SetValue(TintProperty, value);
    }

    public double RestHeight
    {
        get => GetValue(RestHeightProperty);
        set => SetValue(RestHeightProperty, value);
    }

    public double ActiveHeight
    {
        get => GetValue(ActiveHeightProperty);
        set => SetValue(ActiveHeightProperty, value);
    }

    public bool ShowLabels
    {
        get => GetValue(ShowLabelsProperty);
        set => SetValue(ShowLabelsProperty, value);
    }

    public bool IsContinuous
    {
        get => GetValue(IsContinuousProperty);
        set => SetValue(IsContinuousProperty, value);
    }

    public double LabelFontSize
    {
        get => GetValue(LabelFontSizeProperty);
        set => SetValue(LabelFontSizeProperty, value);
    }

    public double LabelSpacing
    {
        get => GetValue(LabelSpacingProperty);
        set => SetValue(LabelSpacingProperty, value);
    }

    public double KeyboardStep
    {
        get => GetValue(KeyboardStepProperty);
        set => SetValue(KeyboardStepProperty, value);
    }

    public double BarActivation
    {
        get => GetValue(BarActivationProperty);
        set => SetValue(BarActivationProperty, value);
    }

    public double LabelActivation
    {
        get => GetValue(LabelActivationProperty);
        set => SetValue(LabelActivationProperty, value);
    }

    // MARK: Displayed value

    /// <summary>
    /// What the bar paints: the live drag while dragging, the released target
    /// until the player catches up, and otherwise the player's own position.
    /// </summary>
    private double Current =>
        _dragging ? _scrubValue : _settlingValue ?? Position;

    private double Progress
    {
        get
        {
            var duration = Duration;
            if (duration <= 0 || double.IsNaN(duration)) return 0;
            return Math.Clamp(Current / duration, 0, 1);
        }
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);

        if (change.Property == TrackKeyProperty)
        {
            CancelSettle();
            _dragging = false;
            LabelActivation = 0;
        }
        else if (change.Property == PositionProperty && _settlingValue is { } settling)
        {
            // The player has arrived where we sent it; hand the display back.
            if (Math.Abs(change.GetNewValue<double>() - settling) <= SettleTolerance)
                CancelSettle();
        }
    }

    // MARK: Layout

    private double BandHeight => Math.Max(RestHeight, ActiveHeight);

    private double LabelHeight => ShowLabels ? Math.Ceiling(LabelFontSize * ScrubLabelScale * 1.35) : 0;

    private double TotalHeight => BandHeight + (ShowLabels ? LabelSpacing + LabelHeight : 0);

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? 0 : availableSize.Width;
        return new Size(width, TotalHeight);
    }

    // MARK: Input

    private bool IsInBand(Point point)
    {
        var band = BandHeight;
        return point.Y >= -HitSlop && point.Y <= band + HitSlop;
    }

    private double TimeAt(double x)
    {
        var width = Bounds.Width;
        if (width <= 0) return 0;
        var fraction = Math.Clamp(x / width, 0, 1);
        var duration = Duration;
        return duration > 0 && !double.IsNaN(duration) ? fraction * duration : 0;
    }

    protected override void OnPointerEntered(PointerEventArgs e)
    {
        base.OnPointerEntered(e);
        UpdateHover(e.GetPosition(this));
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        _hovering = false;
        if (!_dragging) BarActivation = 0;
    }

    private void UpdateHover(Point point)
    {
        _hovering = IsInBand(point);
        if (!_dragging) BarActivation = _hovering ? 1 : 0;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (Duration <= 0) return;
        var point = e.GetCurrentPoint(this);
        if (!point.Properties.IsLeftButtonPressed || !IsInBand(point.Position)) return;

        CancelSettle();
        _dragging = true;
        BarActivation = 1;
        LabelActivation = 1;
        _scrubValue = TimeAt(point.Position.X);
        if (IsContinuous) Position = _scrubValue;
        Focus(NavigationMethod.Pointer);
        e.Pointer.Capture(this);
        e.Handled = true;
        InvalidateVisual();
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var point = e.GetPosition(this);
        if (!_dragging)
        {
            UpdateHover(point);
            return;
        }

        // Track hover through the drag as well, so releasing with the pointer
        // still on the bar leaves it grown rather than snapping flat.
        _hovering = IsInBand(point);
        _scrubValue = TimeAt(point.X);
        if (IsContinuous) Position = _scrubValue;
        e.Handled = true;
        InvalidateVisual();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (!_dragging) return;

        var target = TimeAt(e.GetPosition(this).X);
        _dragging = false;
        _scrubValue = target;
        e.Pointer.Capture(null);
        LabelActivation = 0;
        BarActivation = _hovering ? 1 : 0;
        e.Handled = true;

        if (IsContinuous)
        {
            Position = target;
            InvalidateVisual();
            return;
        }

        BeginSettle(target);
        SeekCommand?.Execute(target);
        InvalidateVisual();
    }

    /// <summary>
    /// Keyboard focus grows the bar. A hand-drawn control gets no focus adorner
    /// from the theme, and arrow keys move the playhead, so there has to be
    /// something on screen saying which control they will reach.
    /// </summary>
    protected override void OnGotFocus(FocusChangedEventArgs e)
    {
        base.OnGotFocus(e);
        if (e.NavigationMethod is NavigationMethod.Tab or NavigationMethod.Directional)
            BarActivation = 1;
    }

    protected override void OnLostFocus(FocusChangedEventArgs e)
    {
        base.OnLostFocus(e);
        if (!_dragging && !_hovering) BarActivation = 0;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (Duration <= 0) return;

        var step = e.Key switch
        {
            Key.Left or Key.Down => -KeyboardStep,
            Key.Right or Key.Up => KeyboardStep,
            Key.PageDown => -KeyboardStep * 6,
            Key.PageUp => KeyboardStep * 6,
            Key.Home => double.NegativeInfinity,
            Key.End => double.PositiveInfinity,
            _ => 0,
        };
        if (step == 0) return;

        var target = double.IsInfinity(step)
            ? (step < 0 ? 0 : Duration)
            : Math.Clamp(Current + step, 0, Duration);

        if (IsContinuous)
        {
            Position = target;
        }
        else
        {
            BeginSettle(target);
            SeekCommand?.Execute(target);
        }
        e.Handled = true;
        InvalidateVisual();
    }

    // MARK: Settling

    private void BeginSettle(double target)
    {
        CancelSettle();
        _settlingValue = target;
        _settleTimer = new DispatcherTimer { Interval = SettleTimeout };
        _settleTimer.Tick += OnSettleTimeout;
        _settleTimer.Start();
    }

    private void OnSettleTimeout(object? sender, EventArgs e) => CancelSettle();

    private void CancelSettle()
    {
        if (_settleTimer is not null)
        {
            _settleTimer.Stop();
            _settleTimer.Tick -= OnSettleTimeout;
            _settleTimer = null;
        }
        if (_settlingValue is null) return;
        _settlingValue = null;
        InvalidateVisual();
    }

    protected override void OnDetachedFromLogicalTree(LogicalTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromLogicalTree(e);
        CancelSettle();
    }

    // MARK: Render

    public override void Render(DrawingContext context)
    {
        var width = Bounds.Width;
        if (width <= 0) return;
        if (Tint is not ISolidColorBrush tint) return;

        var barT = Math.Clamp(BarActivation, 0, 1);
        var labelT = Math.Clamp(LabelActivation, 0, 1);

        var height = Lerp(RestHeight, ActiveHeight, barT);
        var top = (BandHeight - height) / 2;
        var radius = height / 2;

        var rail = new Rect(0, top, width, height);
        context.DrawRectangle(
            Tinted(tint, Lerp(RestTrackOpacity, ActiveTrackOpacity, barT)),
            null, new RoundedRect(rail, radius));

        // The fill is never narrower than it is tall: a capsule shorter than its
        // own corner radius degenerates into a lens, so at 0% the bar would show
        // a squashed sliver rather than nothing at all.
        var filled = Math.Clamp(width * Progress, 0, width);
        if (filled > 0)
        {
            var fill = new Rect(0, top, Math.Max(filled, height), height);
            context.DrawRectangle(
                Tinted(tint, Lerp(RestFillOpacity, ActiveFillOpacity, Math.Max(labelT, barT * 0.5))),
                null, new RoundedRect(fill, radius));
        }

        if (!ShowLabels) return;
        RenderLabels(context, tint, width, labelT);
    }

    private void RenderLabels(DrawingContext context, ISolidColorBrush tint, double width, double labelT)
    {
        var duration = Duration;
        var current = duration > 0 ? Math.Clamp(Current, 0, duration) : 0;
        var remaining = Math.Max(duration - current, 0);

        var weight = labelT > 0.5 ? FontWeight.SemiBold : FontWeight.Normal;
        var typeface = new Typeface(InterFont, FontStyle.Normal, weight);
        var brush = Tinted(tint, Lerp(RestLabelOpacity, ActiveLabelOpacity, labelT));
        var size = LabelFontSize;
        var digit = DigitWidth(typeface, size);
        var scale = Lerp(1, ScrubLabelScale, labelT);
        var baseline = BandHeight + LabelSpacing;

        var elapsed = FormatClock(current);
        // U+2212 MINUS SIGN, not a hyphen: it is the width of a digit, so the
        // remaining label does not jog left when the leading "−" appears.
        var left = "−" + FormatClock(remaining);

        // Each label scales away from the edge it is pinned to, so the pair
        // grows outward from the bar's ends rather than drifting inward, and
        // about its own middle so it does not creep down the band as it grows.
        DrawScaled(context, elapsed, typeface, size, brush, digit,
                   anchorX: 0, bandTop: baseline, scale: scale, rightAligned: false);
        DrawScaled(context, left, typeface, size, brush, digit,
                   anchorX: width, bandTop: baseline, scale: scale, rightAligned: true);

        var format = FormatLabel;
        if (!string.IsNullOrWhiteSpace(format))
            DrawFormatBadge(context, tint, format!, width, baseline);
    }

    /// <summary>
    /// Draw a clock string on a fixed digit grid, so the label does not shimmer
    /// as the seconds tick over. Inter is proportional and its "1" is much
    /// narrower than its "0"; laying every digit out on one advance is what
    /// SwiftUI's <c>.monospacedDigit()</c> does for the phone.
    /// </summary>
    private static void DrawMono(
        DrawingContext context, string text, Typeface typeface, double size,
        IBrush brush, Point origin, double digitWidth)
    {
        var x = origin.X;
        foreach (var ch in text)
        {
            var glyph = Text(ch.ToString(), typeface, size, brush);
            var advance = char.IsDigit(ch) ? digitWidth : glyph.Width;
            var offset = char.IsDigit(ch) ? (digitWidth - glyph.Width) / 2 : 0;
            context.DrawText(glyph, new Point(x + offset, origin.Y));
            x += advance;
        }
    }

    private static double MonoWidth(string text, Typeface typeface, double size, double digitWidth)
    {
        var width = 0.0;
        foreach (var ch in text)
        {
            width += char.IsDigit(ch)
                ? digitWidth
                : Text(ch.ToString(), typeface, size, Brushes.White).Width;
        }
        return width;
    }

    private void DrawScaled(
        DrawingContext context, string text, Typeface typeface, double size,
        IBrush brush, double digitWidth, double anchorX, double bandTop, double scale, bool rightAligned)
    {
        var width = MonoWidth(text, typeface, size, digitWidth);
        var textHeight = Text("0", typeface, size, Brushes.White).Height;
        var top = bandTop + (LabelHeight - textHeight) / 2;
        var centreY = bandTop + LabelHeight / 2;
        var originX = rightAligned ? anchorX - width : anchorX;
        using (context.PushTransform(
                   Matrix.CreateTranslation(-anchorX, -centreY)
                   * Matrix.CreateScale(scale, scale)
                   * Matrix.CreateTranslation(anchorX, centreY)))
        {
            DrawMono(context, text, typeface, size, brush, new Point(originX, top), digitWidth);
        }
    }

    /// <summary>
    /// The codec pill, centred between the two time labels. A fixed light wash
    /// rather than a themed surface, matching the phone: the bar sits under
    /// artwork-tinted chrome on iOS, and a sampled background made this muddy.
    /// </summary>
    private void DrawFormatBadge(
        DrawingContext context, ISolidColorBrush tint, string label, double width, double top)
    {
        var typeface = new Typeface(InterFont, FontStyle.Normal, FontWeight.SemiBold);
        var size = LabelFontSize - 1.5;
        var text = Text(label, typeface, size, Tinted(tint, 0.72));

        var padX = 7.0;
        var padY = 2.5;
        var pillWidth = text.Width + padX * 2;
        var pillHeight = text.Height + padY * 2;
        var pillTop = top + (LabelHeight - pillHeight) / 2;
        var pill = new Rect((width - pillWidth) / 2, pillTop, pillWidth, pillHeight);
        var radius = pillHeight / 2;

        context.DrawRectangle(
            Tinted(tint, 0.14),
            new Pen(Tinted(tint, 0.12), 1),
            new RoundedRect(pill, radius));
        context.DrawText(text, new Point(pill.X + padX, pill.Y + padY));
    }

    // MARK: Helpers

    private static readonly CultureInfo Culture = CultureInfo.InvariantCulture;

    private static FormattedText Text(string value, Typeface typeface, double size, IBrush brush) =>
        new(value, Culture, FlowDirection.LeftToRight, typeface, size, brush);

    private static double DigitWidth(Typeface typeface, double size) =>
        Text("0", typeface, size, Brushes.White).Width;

    private static double Lerp(double from, double to, double t) => from + (to - from) * t;

    private static IBrush Tinted(ISolidColorBrush tint, double opacity)
    {
        var color = tint.Color;
        var alpha = (byte)Math.Clamp(Math.Round(color.A * opacity), 0, 255);
        return new ImmutableSolidColorBrush(Color.FromArgb(alpha, color.R, color.G, color.B));
    }

    /// <summary>m:ss, or h:mm:ss past the hour — the same shape every Mozz client uses.</summary>
    private static string FormatClock(double seconds)
    {
        if (double.IsNaN(seconds) || seconds < 0) seconds = 0;
        var span = TimeSpan.FromSeconds(Math.Floor(seconds));
        return span.TotalHours >= 1
            ? $"{(int)span.TotalHours}:{span.Minutes:00}:{span.Seconds:00}"
            : $"{span.Minutes}:{span.Seconds:00}";
    }
}

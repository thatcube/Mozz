using System.Collections.ObjectModel;

namespace Mozz.Desktop.ViewModels;

public static class DesktopLayout
{
    /// <summary>
    /// The content pane is wide enough for the fixed desktop chrome: a full
    /// 248px navigation rail, a three-zone transport bar, and detail heroes with
    /// art and text side by side.
    /// </summary>
    public const double ExpandedWidth = 1100;

    /// <summary>
    /// Below this width the icon rail itself costs more than it saves: the
    /// remaining pane is too narrow for a two-column detail hero plus comfortable
    /// text, so navigation has to leave the flow and come back as an overlay.
    /// </summary>
    public const double MediumWidth = 760;

    public const double ExpandedSidebarWidth = 248;
    public const double MediumSidebarWidth = 72;

    public const double AlbumTilePitch = 196;
    public const double ArtistTilePitch = 178;
    public const double GenreTilePitch = 236;
    public const double PlaylistTilePitch = 236;
    public const double TrackCardPitch = 320;
    public const double HomeMixTilePitch = 430;

    public static int ColumnsFor(double width, double pitch) => Math.Max(1, (int)(width / pitch));

    public static DesktopLayoutTier TierForWindowWidth(double width)
    {
        if (width >= ExpandedWidth) return DesktopLayoutTier.Expanded;
        if (width >= MediumWidth) return DesktopLayoutTier.Medium;
        return DesktopLayoutTier.Compact;
    }
}

public enum DesktopLayoutTier
{
    Compact,
    Medium,
    Expanded
}

/// <summary>
/// A grid of items presented as a list of rows, so it can be virtualized.
///
/// Avalonia ships exactly one virtualizing panel, <c>VirtualizingStackPanel</c>,
/// and no virtualizing wrap or grid layout. A <c>WrapPanel</c> inside an
/// <c>ItemsControl</c> realizes every item it is given: fine for the 500-row cap
/// the app used to have, and not fine now that paging is unbounded — scrolling a
/// 12,500-album library would accumulate tens of thousands of live visuals and
/// the window would stop responding long before the end.
///
/// Chunking the items into rows and letting a <c>VirtualizingStackPanel</c> own
/// the rows gets virtualization for free: only the rows on screen are realized,
/// and each row lays out its handful of tiles horizontally. It is the standard
/// answer to this exact gap, and it costs one indirection rather than a custom
/// panel implementation.
///
/// Appends do not rebuild the whole grid. A page of 200 arriving into 12,000
/// existing items would otherwise clear and refill an ObservableCollection that
/// the UI is bound to, which resets scroll position and re-realizes everything —
/// the opposite of the point. Only the partial last row is replaced.
/// </summary>
public sealed class GridRows<T>
{
    private readonly List<T> _flat = [];
    private int _columns = 1;

    public ObservableCollection<IReadOnlyList<T>> Rows { get; } = [];

    public int Columns => _columns;
    public int Count => _flat.Count;

    /// <summary>
    /// Set how many items fit across. A no-op when unchanged, because this is
    /// driven by a layout event that fires far more often than the width
    /// actually changes.
    /// </summary>
    public void SetColumns(int columns)
    {
        columns = Math.Max(1, columns);
        if (columns == _columns) return;
        _columns = columns;
        Rebuild();
    }

    public void Reset(IEnumerable<T>? items)
    {
        _flat.Clear();
        if (items is not null) _flat.AddRange(items);
        Rebuild();
    }

    public void Append(IEnumerable<T>? items)
    {
        if (items is null) return;
        var added = items as IReadOnlyList<T> ?? items.ToList();
        if (added.Count == 0) return;

        // The last row may be short; it has to absorb items before new rows
        // start, or the grid grows a ragged hole in the middle of itself.
        if (Rows.Count > 0 && Rows[^1].Count < _columns)
        {
            var start = _flat.Count - Rows[^1].Count;
            _flat.AddRange(added);
            Rows[^1] = Slice(start);
            AppendRowsFrom(start + Rows[^1].Count);
        }
        else
        {
            var start = _flat.Count;
            _flat.AddRange(added);
            AppendRowsFrom(start);
        }
    }

    private void AppendRowsFrom(int index)
    {
        for (var i = index; i < _flat.Count; i += _columns) Rows.Add(Slice(i));
    }

    private IReadOnlyList<T> Slice(int start)
        => _flat.GetRange(start, Math.Min(_columns, _flat.Count - start));

    private void Rebuild()
    {
        Rows.Clear();
        AppendRowsFrom(0);
    }
}

using Avalonia.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public abstract record DetailRow;

public sealed record AlbumHeroRow(Album Album, string Metadata) : DetailRow;

/// <summary>
/// The artist hero, with the picture it should actually draw.
/// </summary>
/// <remarks>
/// <paramref name="HeroKey"/> rather than reading the artist's own key at the
/// binding: most artists in a real library have no photograph of their own, and
/// the page was drawing a 92-point letter on an empty rectangle for them. The
/// core already prefers a representative album cover when an artist has no art
/// (ArtistDetailPresentation.heroArtworkKey) and the phones rely on it; this
/// carries the same rule to the row so the hero has something to bloom with
/// whichever way the key arrives.
/// </remarks>
public sealed record ArtistHeroRow(Artist Artist, string? HeroKey) : DetailRow
{
    /// <summary>
    /// Whether there is a picture to lead with at all.
    ///
    /// Some artists have neither a photograph of their own nor an album with a
    /// cover, and for them the hero was a 440-point block of deterministic
    /// colour with a music note in the middle — a placeholder the size of the
    /// page, ending in a hard edge against a page it shares no colour with,
    /// because there was no artwork to take a tone from either. A page with no
    /// picture should not be shaped like one.
    /// </summary>
    public bool HasHero => HeroKey is { Length: > 0 };
}

public sealed record PlaylistHeroRow(Playlist Playlist, string Metadata) : DetailRow;

public sealed record MixHeroRow(HomeMixTile Mix, string Metadata, string? Subtitle) : DetailRow;

public sealed record GenreHeroRow(string Genre, string Metadata) : DetailRow;

public sealed record DetailSectionRow(string Title) : DetailRow;

public sealed record DetailAlbumShelfRow(IReadOnlyList<Album> Albums) : DetailRow;

public sealed record TrackCard(Track Track, string Subtitle);

public sealed record DetailTrackGridRow(IReadOnlyList<TrackCard> Tracks) : DetailRow;

public sealed record AlbumTrackItemRow(AlbumTrackRow Row) : DetailRow;

public sealed record PlaylistTrackHeaderRow : DetailRow;

public sealed record PlaylistTrackItemRow(Track Track) : DetailRow;

/// <summary>
/// One lyric line, at its depth in the column.
///
/// Observable, and mutated in place rather than replaced: the active line moves
/// on every position tick (ten a second), and rebuilding the collection that
/// often threw away every container the list had — which reset the scroll
/// position, so the column could never follow the song in the first place.
/// Only <see cref="Distance"/> actually changes, so only it is raised.
/// </summary>
public sealed partial class LyricLineRow(string text, double? startSeconds) : ObservableObject
{
    public string Text { get; } = text;

    public double? StartSeconds { get; } = startSeconds;

    /// <summary>Whether this line can be clicked to seek to it.</summary>
    public bool IsSynced => StartSeconds is not null;

    /// <summary>
    /// How many lines away the sung line is, or null when nothing is being sung
    /// — unsynced lyrics, or the run-up before the first timestamp.
    /// </summary>
    private int? _distance;

    public int? Distance
    {
        get => _distance;
        set
        {
            if (_distance == value) return;
            _distance = value;
            OnPropertyChanged(nameof(Distance));
            OnPropertyChanged(nameof(IsActive));
            OnPropertyChanged(nameof(LineOpacity));
            OnPropertyChanged(nameof(LineEffect));
            OnPropertyChanged(nameof(LineWeight));
        }
    }

    public bool IsActive => _distance == 0;

    public double LineOpacity => LyricDepth.Opacity(_distance);

    public double BlurRadius => LyricDepth.BlurRadius(_distance);

    /// <summary>
    /// The softening, or nothing at all when there is none to apply.
    ///
    /// Null rather than a zero-radius blur on purpose: an effect makes its
    /// subject composite offscreen whatever its radius, and the column does not
    /// virtualise, so a sharp line carrying an idle blur would be paying a
    /// render target for a no-op.
    /// </summary>
    public IEffect? LineEffect
    {
        get
        {
            var radius = BlurRadius;
            return radius <= 0 ? null : new BlurEffect { Radius = radius };
        }
    }

    /// <summary>The sung line carries the extra weight; the rest sit at medium.</summary>
    public FontWeight LineWeight => _distance == 0 ? FontWeight.Bold : FontWeight.Medium;

    /// <summary>
    /// An empty line is a beat of silence in the song, and it has to keep its
    /// height or the column jumps over it.
    /// </summary>
    public string DisplayText => string.IsNullOrEmpty(Text) ? " " : Text;
}

public static class LyricLineSelector
{
    public static int? ActiveIndex(IReadOnlyList<LyricLine>? lines, double positionSeconds)
    {
        if (lines is null || lines.Count == 0 || !double.IsFinite(positionSeconds)) return null;
        int? active = null;
        for (var i = 0; i < lines.Count; i++)
        {
            if (lines[i].StartSeconds is not { } start) continue;
            if (start <= positionSeconds) active = i;
            else break;
        }
        return active;
    }

    public static IReadOnlyList<LyricLineRow> Rows(IReadOnlyList<LyricLine>? lines, int? activeIndex)
    {
        if (lines is null) return [];
        var rows = lines.Select(line => new LyricLineRow(line.Text, line.StartSeconds)).ToList();
        Light(rows, activeIndex);
        return rows;
    }

    /// <summary>
    /// Point the column at <paramref name="activeIndex"/> by setting each row's
    /// distance from it. In place, because these rows are already on screen.
    /// </summary>
    public static void Light(IReadOnlyList<LyricLineRow> rows, int? activeIndex)
    {
        for (var i = 0; i < rows.Count; i++)
        {
            rows[i].Distance = activeIndex is { } active ? Math.Abs(i - active) : null;
        }
    }
}

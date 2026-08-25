using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public abstract record DetailRow;

public sealed record AlbumHeroRow(Album Album, string Metadata) : DetailRow;

public sealed record ArtistHeroRow(Artist Artist) : DetailRow;

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

public sealed record LyricLineRow(string Text, double? StartSeconds, bool IsActive)
{
    public string DisplayText => IsActive ? $"▶ {Text}" : Text;
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
        return lines.Select((line, i) => new LyricLineRow(
                line.Text,
                line.StartSeconds,
                activeIndex == i))
            .ToList();
    }
}

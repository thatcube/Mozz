using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public sealed record AlbumTrackRow(
    Track Track,
    string TrackNumberText,
    bool StartsDisc,
    string? DiscTitle);

public static class MediaDetailFormatting
{
    public static IReadOnlyList<AlbumTrackRow> AlbumTrackRows(IEnumerable<Track> tracks)
    {
        var ordered = OrderAlbumTracks(tracks).ToList();
        var hasMultipleDiscs = ordered
            .Select(t => t.DiscNumber ?? 1)
            .Distinct()
            .Skip(1)
            .Any();

        var rows = new List<AlbumTrackRow>(ordered.Count);
        int? previousDisc = null;
        foreach (var track in ordered)
        {
            var disc = track.DiscNumber ?? 1;
            var startsDisc = hasMultipleDiscs && disc != previousDisc;
            rows.Add(new AlbumTrackRow(
                track,
                track.TrackNumber is > 0 ? track.TrackNumber.Value.ToString() : "—",
                startsDisc,
                startsDisc ? $"Disc {disc}" : null));
            previousDisc = disc;
        }

        return rows;
    }

    public static IEnumerable<Track> OrderAlbumTracks(IEnumerable<Track> tracks) =>
        tracks.OrderBy(t => t.DiscNumber ?? 1)
              .ThenBy(t => t.TrackNumber ?? int.MaxValue)
              .ThenBy(t => t.Title, StringComparer.CurrentCultureIgnoreCase)
              .ThenBy(t => t.Id);

    public static IEnumerable<Track> OrderArtistTracks(IEnumerable<Track> tracks) =>
        tracks.OrderBy(t => t.AlbumTitle ?? string.Empty, StringComparer.CurrentCultureIgnoreCase)
              .ThenBy(t => t.DiscNumber ?? 1)
              .ThenBy(t => t.TrackNumber ?? int.MaxValue)
              .ThenBy(t => t.Title, StringComparer.CurrentCultureIgnoreCase)
              .ThenBy(t => t.Id);

    public static string AlbumMeta(Album album, IReadOnlyCollection<Track> tracks)
    {
        var parts = new List<string>();
        if (album.Year is not null) parts.Add(album.Year.Value.ToString());

        var count = tracks.Count > 0 ? tracks.Count : album.TrackCount ?? 0;
        if (count > 0) parts.Add(count == 1 ? "1 song" : $"{count} songs");

        var duration = FormatLongDuration(tracks.Sum(t => t.DurationSeconds));
        if (!string.IsNullOrEmpty(duration)) parts.Add(duration);

        return string.Join(" · ", parts);
    }

    public static string ArtistMeta(IReadOnlyCollection<Album> albums, IReadOnlyCollection<Track> tracks)
    {
        var parts = new List<string>();
        if (albums.Count > 0) parts.Add(albums.Count == 1 ? "1 album" : $"{albums.Count} albums");
        if (tracks.Count > 0) parts.Add(tracks.Count == 1 ? "1 song" : $"{tracks.Count} songs");
        return string.Join(" · ", parts);
    }

    public static string FormatLongDuration(double seconds)
    {
        if (seconds <= 0 || double.IsNaN(seconds)) return string.Empty;
        var roundedMinutes = (int)Math.Round(seconds / 60.0, MidpointRounding.AwayFromZero);
        if (roundedMinutes < 60) return $"{roundedMinutes} min";

        var hours = roundedMinutes / 60;
        var minutes = roundedMinutes % 60;
        return minutes == 0 ? $"{hours} hr" : $"{hours} hr {minutes} min";
    }
}

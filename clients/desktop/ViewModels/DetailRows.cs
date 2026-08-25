using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public abstract record DetailRow;

public sealed record AlbumHeroRow(Album Album, string Metadata) : DetailRow;

public sealed record ArtistHeroRow(Artist Artist) : DetailRow;

public sealed record PlaylistHeroRow(Playlist Playlist, string Metadata) : DetailRow;

public sealed record MixHeroRow(HomeMixTile Mix, string Metadata, string? Subtitle) : DetailRow;

public sealed record DetailSectionRow(string Title) : DetailRow;

public sealed record DetailAlbumShelfRow(IReadOnlyList<Album> Albums) : DetailRow;

public sealed record TrackCard(Track Track, string Subtitle);

public sealed record DetailTrackGridRow(IReadOnlyList<TrackCard> Tracks) : DetailRow;

public sealed record AlbumTrackItemRow(AlbumTrackRow Row) : DetailRow;

public sealed record PlaylistTrackHeaderRow : DetailRow;

public sealed record PlaylistTrackItemRow(Track Track) : DetailRow;

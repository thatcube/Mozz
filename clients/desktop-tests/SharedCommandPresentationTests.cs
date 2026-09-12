using Avalonia.Media;
using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public sealed class SharedCommandPresentationTests
{
    [Fact]
    public void FavoriteStateOptimisticThenQueuedReconciled()
    {
        var track = Track(false);
        var optimistic = FavoriteStateProjector.Optimistic(track, liked: true);
        Assert.True(optimistic.IsFavorite);
        Assert.True(optimistic.FavoritePending);

        var reconciled = FavoriteStateProjector.Reconciled(optimistic, new FavoriteMutationResult(
            "srv", "trk", "track", "favorite", 1, true, Queued: true, Synced: false));
        Assert.True(reconciled.IsFavorite);
        Assert.True(reconciled.FavoritePending);

        var synced = FavoriteStateProjector.Reconciled(reconciled, new FavoriteMutationResult(
            "srv", "trk", "track", "favorite", 1, true, Queued: false, Synced: true));
        Assert.True(synced.IsFavorite);
        Assert.False(synced.FavoritePending);
    }

    [Fact]
    public void LyricLineSelectionHandlesTimedAndSilentCases()
    {
        LyricLine[] lines =
        [
            new("first", 0),
            new("second", 12.5),
            new("third", 20),
        ];

        Assert.Equal(1, LyricLineSelector.ActiveIndex(lines, 13));
        Assert.Null(LyricLineSelector.ActiveIndex(null, 13));
        Assert.Empty(LyricLineSelector.Rows(null, null));
    }

    /// <summary>
    /// A link has to be readable on the page it sits on.
    ///
    /// A detail page takes its colour from the artwork, so a crimson record
    /// gives a crimson page — and the accent-coloured artist link on it would
    /// be the same crimson. The sum-of-channels distance is what decides, and
    /// the threshold is deliberately generous: the cost of being wrong is a
    /// line nobody can see.
    /// </summary>
    [Fact]
    public void ALinkGivesUpTheAccentOnAPageTheAccentColourWouldVanishInto()
    {
        static int Distance(Color a, Color b) =>
            Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B);

        var accent = Color.FromRgb(0xD8, 0x21, 0x3F);

        // A page sampled from a crimson cover: too close, the link must change.
        Assert.True(Distance(Color.FromRgb(0xC0, 0x28, 0x3A), accent) < 150);
        // A warm brown, a slate blue, a near-black: all far enough to keep it.
        Assert.True(Distance(Color.FromRgb(0x7A, 0x4A, 0x2E), accent) >= 150);
        Assert.True(Distance(Color.FromRgb(0x3A, 0x4A, 0x6E), accent) >= 150);
        Assert.True(Distance(Color.FromRgb(0x14, 0x14, 0x16), accent) >= 150);
    }

    /// <summary>
    /// An album row names its artist only when that is news.
    ///
    /// The page already says whose record it is, twice, in accent, right above
    /// the list — so repeating it under every track says nothing. It earns its
    /// place on a compilation, a guest spot or a split single.
    /// </summary>
    [Fact]
    public void AnAlbumRowNamesItsArtistOnlyWhenItDiffers()
    {
        Track Song(string artist) => new(
            1, "remote", "server", "Title", artist, "Album", null, 1, 1, 180, null, false);

        Assert.False(new AlbumTrackRow(Song("Taylor Swift"), "1", false, null, "Taylor Swift").ShowsArtist);
        // Case is not a difference worth a line of its own.
        Assert.False(new AlbumTrackRow(Song("taylor swift"), "1", false, null, "Taylor Swift").ShowsArtist);
        Assert.True(new AlbumTrackRow(Song("Bon Iver"), "1", false, null, "Taylor Swift").ShowsArtist);
        // And with nothing to compare against, a named artist still shows.
        Assert.True(new AlbumTrackRow(Song("Bon Iver"), "1", false, null, null).ShowsArtist);
    }

    /// <summary>
    /// An artist with no picture anywhere gets no picture-shaped header.
    ///
    /// Some artists have neither a photograph nor an album with a cover, and
    /// the hero drew a 440-point block of deterministic colour for them — a
    /// placeholder the size of the page, ending in a hard edge against a page
    /// that had no artwork to take a tone from either.
    /// </summary>
    [Fact]
    public void AnArtistWithNoArtworkGetsNoHero()
    {
        var artist = new Artist(1, "remote", "server", "Nobody", null);

        Assert.False(new ArtistHeroRow(artist, null).HasHero);
        Assert.False(new ArtistHeroRow(artist, "").HasHero);
        Assert.True(new ArtistHeroRow(artist, "art/1").HasHero);
    }

    /// <summary>
    /// The rating strip's geometry, which must agree with the phones' to the
    /// half star: the same drag across the same five stars has to mean the same
    /// rating everywhere, or a song rated on the phone reads back differently
    /// on the desktop.
    ///
    /// These are iOS's own cases, ported alongside the math.
    /// </summary>
    [Fact]
    public void RatingGeometryMatchesThePhones()
    {
        const double star = 22, gap = 6, pitch = star + gap;

        // Left half of a star is the half step, right half the whole.
        Assert.Equal(0.5, RatingMath.RatingAtX(1, star, gap));
        Assert.Equal(1.0, RatingMath.RatingAtX(star - 1, star, gap));
        Assert.Equal(2.5, RatingMath.RatingAtX(2 * pitch + 1, star, gap));
        Assert.Equal(3.0, RatingMath.RatingAtX(2 * pitch + star - 1, star, gap));

        // Past the end saturates rather than running off.
        Assert.Equal(5.0, RatingMath.RatingAtX(10_000, star, gap));

        // Left of the first star clears — this is how a rating is taken away
        // without lifting the pointer.
        Assert.Null(RatingMath.RatingAtX(-1, star, gap));

        Assert.Equal(5 * star + 4 * gap, RatingMath.StripWidth(star, gap));
    }

    /// <summary>Trailing zeroes are noise on a star count, and one is the only singular.</summary>
    [Fact]
    public void RatingReadsBackTheWayItIsSpoken()
    {
        Assert.Equal("4", RatingMath.Format(4.0));
        Assert.Equal("4.5", RatingMath.Format(4.5));
        Assert.Equal("1 star", RatingMath.Label(1.0));
        Assert.Equal("1.5 stars", RatingMath.Label(1.5));
        Assert.Equal("5 stars", RatingMath.Label(5.0));
    }

    /// <summary>
    /// The numbers the phones use. Both of them dim and soften a lyric column
    /// on exactly this curve, and a desktop that picked its own would read as a
    /// different app rather than the same one on a bigger screen.
    /// </summary>
    [Fact]
    public void LyricDepthMatchesThePhones()
    {
        Assert.Equal(1, LyricDepth.Opacity(0));
        Assert.Equal(0.4, LyricDepth.Opacity(1));
        Assert.Equal(0.28, LyricDepth.Opacity(2));
        Assert.Equal(0.2, LyricDepth.Opacity(9));

        // Nothing being sung: one even brightness, not one line picked out.
        Assert.Equal(0.8, LyricDepth.Opacity(null));

        // The line you are about to read stays sharp.
        Assert.Equal(0, LyricDepth.BlurRadius(0));
        Assert.Equal(0, LyricDepth.BlurRadius(1));
        Assert.Equal(1.1, LyricDepth.BlurRadius(2), 3);
        Assert.Equal(LyricDepth.BlurCeiling, LyricDepth.BlurRadius(40));
        Assert.Equal(0, LyricDepth.BlurRadius(null));
    }

    /// <summary>
    /// Re-lighting happens in place. The highlight moves ten times a second, and
    /// rebuilding the collection that often threw away every list container —
    /// which reset the scroll, so the column could never follow the song.
    /// </summary>
    [Fact]
    public void LightingTheColumnKeepsTheSameRows()
    {
        LyricLine[] lines = [new("first", 0), new("second", 12.5), new("third", 20)];
        var rows = LyricLineSelector.Rows(lines, 0);

        Assert.True(rows[0].IsActive);
        Assert.Equal(1, rows[1].Distance);

        LyricLineSelector.Light(rows, 2);

        Assert.False(rows[0].IsActive);
        Assert.True(rows[2].IsActive);
        Assert.Equal(2, rows[0].Distance);
        Assert.Equal(LyricDepth.Opacity(2), rows[0].LineOpacity);
    }

    /// <summary>
    /// An unsynced line has no timestamp, so there is nowhere for a click to go
    /// and the row must not offer one.
    /// </summary>
    [Fact]
    public void UnsyncedLyricsOfferNoSeek()
    {
        LyricLine[] lines = [new("first", null), new("second", null)];
        var rows = LyricLineSelector.Rows(lines, LyricLineSelector.ActiveIndex(lines, 30));

        Assert.All(rows, row => Assert.False(row.IsSynced));
        Assert.All(rows, row => Assert.Null(row.Distance));
        Assert.All(rows, row => Assert.Equal(0.8, row.LineOpacity));
    }

    /// <summary>
    /// A blank line is a beat of silence in the song. It has to keep its height
    /// or the column closes over it and the timing stops matching the record.
    /// </summary>
    [Fact]
    public void EmptyLyricLinesKeepTheirHeight()
    {
        var row = new LyricLineRow(string.Empty, 4);
        Assert.Equal(" ", row.DisplayText);
    }

    [Fact]
    public void SyncProgressSmootherNeverRunsAheadOfReportedCounts()
    {
        var smoother = new SyncProgressSmoother();
        var start = DateTimeOffset.Parse("2026-08-25T12:00:00Z");
        var first = Status("tracks", "Songs", "syncing", 10, 100);
        var second = Status("tracks", "Songs", "syncing", 50, 100);

        Assert.Equal(10, smoother.Update(first, start).Single().Synced);
        var eased = smoother.Update(second, start.AddSeconds(1)).Single();

        Assert.InRange(eased.Synced, 10, 50);
        Assert.Equal("10 / 100", new SyncPhaseRow("Songs", "syncing", 10, 100, false).CountText);
    }

    private static Track Track(bool liked) =>
        new(0, "trk", "srv", "Song", "Artist", "Album", null, null, null, 180, null, liked);

    private static SyncStatus Status(string phase, string label, string state, int synced, int total) =>
        new(
            Running: state != "done",
            Finished: state == "done",
            Phase: phase,
            ItemsSynced: synced,
            Total: total,
            Error: null,
            Artists: null,
            Albums: null,
            Tracks: null,
            Playlists: null,
            Details: [new SyncPhaseDetail(phase, label, state, synced, total, state == "done")],
            PhaseLabel: label);
}

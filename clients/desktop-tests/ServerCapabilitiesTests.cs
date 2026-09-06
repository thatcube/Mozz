using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// "Liked" is not one thing across the three backends, and the desktop used to
/// draw both controls whatever was attached. These pin the shapes the Swift
/// backends actually declare — see `detectCapabilities` in PlexBackend,
/// JellyfinBackend and SubsonicBackend.
/// </summary>
public class ServerCapabilitiesTests
{
    [Fact]
    public void PlexIsRatedWithStarsBecauseItHasNoBooleanFavourite()
    {
        var plex = new ServerCapabilities("plex", SupportsFavorites: false, SupportsRatings: true);

        Assert.Equal(LikeGlyph.Star, plex.LikeGlyph);
    }

    [Fact]
    public void JellyfinIsHeartedBecauseItHasNoRatings()
    {
        var jellyfin = new ServerCapabilities("jellyfin", SupportsFavorites: true, SupportsRatings: false);

        Assert.Equal(LikeGlyph.Heart, jellyfin.LikeGlyph);
    }

    [Fact]
    public void SubsonicHasBothAndTheHeartWins()
    {
        // Subsonic stars *and* rates. One control has to be the like, and the
        // Pixel picks the heart for the same reason: a boolean is what "liked"
        // means everywhere else in the app.
        var subsonic = new ServerCapabilities("subsonic", SupportsFavorites: true, SupportsRatings: true);

        Assert.Equal(LikeGlyph.Heart, subsonic.LikeGlyph);
    }

    [Fact]
    public void AServerThatHasNotAnsweredYetDrawsNeitherControl()
    {
        // Null capabilities are "not yet", not "no": the view model reads them
        // that way so a control never flickers in with the wrong glyph.
        ServerCapabilities? unanswered = null;

        Assert.Null(unanswered?.LikeGlyph);
    }
}

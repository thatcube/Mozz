using Mozz.Desktop.Core.Downloads;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The download file layout is a portable convention shared with the core's
/// Swift <c>DownloadFileStore</c>: both sides must name the same file for a given
/// (server, remote) id, or a download written by the shell is a file the core
/// cannot find. These pin the two halves of that convention — the path shape and
/// the id sanitiser — to the exact rules the core applies.
/// </summary>
public class DownloadLayoutTests
{
    [Fact]
    public void RelativePathJoinsSanitisedIdsWithTheExtension()
    {
        var path = DownloadLayout.RelativePath("server-1", "track-42", "flac");
        Assert.Equal("server-1/track-42.flac", path);
    }

    [Fact]
    public void AnEmptyExtensionFallsBackToAudio()
    {
        // Matches the core: an empty file extension becomes "audio", never a
        // trailing-dot filename.
        var path = DownloadLayout.RelativePath("s", "r", "");
        Assert.Equal("s/r.audio", path);
    }

    [Theory]
    [InlineData("plex://library/metadata/17", "server/plex___library_metadata_17.audio")]
    [InlineData("a/b", "server/a_b.audio")]
    public void DisallowedCharactersBecomeUnderscores(string remoteId, string expected)
    {
        // The Swift rule underscores every character outside [A-Za-z0-9-_.]; an
        // all-disallowed component becomes all underscores rather than collapsing.
        var path = DownloadLayout.RelativePath("server", remoteId, "");
        Assert.Equal(expected, path);
    }

    [Fact]
    public void AnEmptyIdBecomesItemNotAnEmptySegment()
    {
        var path = DownloadLayout.RelativePath("", "", "mp3");
        Assert.Equal("item/item.mp3", path);
    }

    [Theory]
    [InlineData("https://host/media/song.flac", "flac")]
    [InlineData("https://host/media/song.MP3", "mp3")]
    [InlineData("https://host/media/song.m4a?static=true&x=1", "m4a")]
    [InlineData("https://host/stream?id=5", "audio")]
    [InlineData("https://host/media/song.txt", "audio")]
    [InlineData("https://host/media/song.", "audio")]
    [InlineData("", "audio")]
    public void ExtensionIsTakenFromTheUrlOnlyWhenItIsAKnownAudioContainer(string url, string expected)
    {
        Assert.Equal(expected, DownloadLayout.ExtensionFromUrl(url));
    }
}

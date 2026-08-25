using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Pins the desktop's "Latest Release" ordering to the shared core's.
/// </summary>
/// <remarks>
/// The rule lives in <c>Sources/MozzCore/LatestRelease.swift</c> and is mirrored
/// in <see cref="MediaDetailFormatting"/> because it is a pure function over data
/// the client already holds, and a round trip per album would be absurd for a
/// shelf. Mirroring is only safe if it is checked, so these cases are the same
/// cases as <c>Tests/MozzCoreTests/LatestReleaseTests.swift</c>. If someone
/// changes the rule on one side, this fails rather than letting the phone and the
/// desktop quietly name different records as an artist's latest.
/// </remarks>
public class LatestReleaseTests
{
    private static Album A(int? year, double? addedAt = null, string title = "x") =>
        new(Id: 0, RemoteId: title, ServerId: "srv", Title: title, ArtistName: "a",
            ArtistRemoteId: "ar", Year: year, TrackCount: 10, ArtworkKey: null,
            AddedAt: addedAt);

    [Fact]
    public void ALaterYearWins()
    {
        Assert.Equal("new", MediaDetailFormatting.LatestRelease(
            new[] { A(2019, title: "old"), A(2024, title: "new") })!.Title);
    }

    [Fact]
    public void ADatedReleaseOutranksAnUndatedOne_InBothDirections()
    {
        Assert.True(MediaDetailFormatting.IsNewer(A(1998), A(null)));
        Assert.False(MediaDetailFormatting.IsNewer(A(null), A(1998)));
    }

    [Fact]
    public void SameYearFallsThroughToWhenTheLibrarySawIt()
    {
        Assert.True(MediaDetailFormatting.IsNewer(A(2024, 200), A(2024, 100)));
        Assert.False(MediaDetailFormatting.IsNewer(A(2024, 100), A(2024, 200)));
    }

    [Fact]
    public void WithNeitherYearNorDateTheTitleDecides()
    {
        Assert.True(MediaDetailFormatting.IsNewer(A(null, null, "Aaa"), A(null, null, "Bbb")));
        Assert.False(MediaDetailFormatting.IsNewer(A(null, null, "Bbb"), A(null, null, "Aaa")));
    }

    [Fact]
    public void AnEmptyListHasNoLatestRelease()
    {
        Assert.Null(MediaDetailFormatting.LatestRelease(System.Array.Empty<Album>()));
    }

    [Fact]
    public void AnUndatedDiscographyStillHasAStableAnswer()
    {
        // The case that actually happens: a self-hosted server returns a whole
        // artist with no year on anything. The answer must not depend on the
        // order the rows arrived in, or two clients disagree about the same
        // library.
        var forwards = new[] { A(null, null, "Bbb"), A(null, null, "Aaa"), A(null, null, "Ccc") };
        var backwards = new[] { A(null, null, "Ccc"), A(null, null, "Bbb"), A(null, null, "Aaa") };
        Assert.Equal("Aaa", MediaDetailFormatting.LatestRelease(forwards)!.Title);
        Assert.Equal("Aaa", MediaDetailFormatting.LatestRelease(backwards)!.Title);
    }
}

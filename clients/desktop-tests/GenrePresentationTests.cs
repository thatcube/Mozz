using Mozz.Desktop.Core;
using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

public class GenrePresentationTests
{
    [Fact]
    public void BuildsDistinctSortedGenreTiles()
    {
        var rows = GenrePresentation.Build(["Rock", " jazz ", "rock", "Ambient", ""]);

        Assert.Equal(["Ambient", "jazz", "Rock"], rows.Select(r => r.Name).ToArray());
    }

    [Fact]
    public void FormatsGenreAlbumMetadata()
    {
        var albums = new[]
        {
            new Album(1, "one", "server", "One", "Artist", null, null, null, null),
            new Album(2, "two", "server", "Two", "Artist", null, null, null, null),
        };

        Assert.Equal("2 albums", GenrePresentation.Metadata("Rock", albums));
    }
}

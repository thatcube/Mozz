using System.Text.Json;
using Google.Protobuf;
using Mozz.V1;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Conformance against <c>spec/schema/wire-fixtures.json</c> — the same bytes
/// the Swift suite checks itself against, in <c>WireFixtureConformanceTests</c>.
///
/// This is the test that earns the schema. Two clients agreeing with themselves
/// proves nothing; what matters is that a message produced on one platform is
/// understood on another, because the whole reason for describing commands
/// rather than hand-writing them is that the platforms could previously drift
/// apart without anything noticing.
///
/// The fixture bytes came from <c>protoc --encode</c>, so neither client is the
/// definition of the format — each is measured against a neutral third party.
/// </summary>
public class WireFixtureConformanceTests
{
    private sealed record Fixture(string Name, string Base64);

    /// <summary>
    /// Walk up to the repository root. The fixtures deliberately are not copied
    /// into the test output: they belong to <c>spec/</c>, shared with every other
    /// implementation, and a second copy is a copy that can drift.
    /// </summary>
    private static byte[] Bytes(string name)
    {
        var directory = AppContext.BaseDirectory;
        string? found = null;
        for (var i = 0; i < 8 && directory is not null; i++)
        {
            var candidate = Path.Combine(directory, "spec", "schema", "wire-fixtures.json");
            if (File.Exists(candidate)) { found = candidate; break; }
            directory = Path.GetDirectoryName(directory);
        }

        Assert.True(found is not null, "could not locate spec/schema/wire-fixtures.json above the test binary");

        using var document = JsonDocument.Parse(File.ReadAllText(found!));
        foreach (var element in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            if (element.GetProperty("name").GetString() == name)
            {
                return Convert.FromBase64String(element.GetProperty("base64").GetString()!);
            }
        }

        Assert.Fail($"no fixture named {name}");
        return [];
    }

    [Fact]
    public void DecodesArtistRequestProducedByAnotherPlatform()
    {
        var request = Request.Parser.ParseFrom(Bytes("artist-request"));

        Assert.Equal(42ul, request.Id);
        Assert.Equal(Request.CommandOneofCase.Artist, request.CommandCase);
        Assert.Equal("plex-a1b2c3", request.Artist.ServerId);
        Assert.Equal("/library/metadata/9987", request.Artist.RemoteId);
    }

    [Fact]
    public void PreservesAnOpaqueCursorExactly()
    {
        var request = Request.Parser.ParseFrom(Bytes("albums-request-paged"));

        Assert.Equal(Request.CommandOneofCase.Albums, request.CommandCase);
        Assert.Equal("jellyfin-77", request.Albums.ServerId);
        Assert.Equal(200, request.Albums.Limit);
        // The cursor is the core's to interpret. The desktop must hand back
        // exactly what it was given — not normalised, re-encoded or trimmed.
        Assert.Equal("eyJvIjoyMDB9", request.Albums.After.Token);
    }

    [Fact]
    public void TreatsFailureAsAResultRatherThanASideChannel()
    {
        var response = Response.Parser.ParseFrom(Bytes("failure-response"));

        Assert.Equal(Response.ResultOneofCase.Failure, response.ResultCase);
        Assert.Equal("artist not found: /library/metadata/9987", response.Failure.Message);
    }

    [Fact]
    public void DecodesAnUnpromptedSubscriptionEvent()
    {
        var evt = Event.Parser.ParseFrom(Bytes("library-changed-event"));

        Assert.Equal(3ul, evt.Token.Id);
        Assert.Equal(Event.PayloadOneofCase.LibraryChanged, evt.PayloadCase);
        Assert.Equal(new[] { "album", "track" }, evt.LibraryChanged.ChangedEntities);
    }

    /// <summary>
    /// Re-encoding must reproduce the original bytes.
    ///
    /// Decoding alone would still pass if two fields swapped numbers in a
    /// mutually compatible way. Comparing the bytes back out is what pins the
    /// wire format itself, and it is the half that catches a renumbered field
    /// in a schema change that was regenerated but not thought through.
    /// </summary>
    [Theory]
    [InlineData("artist-request")]
    [InlineData("albums-request-paged")]
    public void ReEncodingReproducesTheFixtureBytes(string name)
    {
        var original = Bytes(name);
        var round = Request.Parser.ParseFrom(original).ToByteArray();

        Assert.Equal(original, round);
    }

    /// <summary>
    /// A message from a newer core, carrying a command this build has never
    /// heard of, must not throw — it must be recognisably unhandled.
    ///
    /// This matters because the desktop and the core ship separately. The old
    /// hand-written facade answered an unknown command with a runtime string
    /// error; here it is a case the compiler can see, so a client can say "this
    /// build is too old for that" instead of failing obscurely.
    /// </summary>
    [Fact]
    public void AnUnknownCommandParsesAsNoneRatherThanThrowing()
    {
        // Field 99 inside the command oneof: a command number no current build
        // declares. Hand-built rather than generated, precisely because the
        // generator cannot produce a command it does not know about.
        var unknown = new byte[] { 0x08, 0x2A, 0xDA, 0x06, 0x00 };

        var request = Request.Parser.ParseFrom(unknown);

        Assert.Equal(42ul, request.Id);
        Assert.Equal(Request.CommandOneofCase.None, request.CommandCase);
    }
}

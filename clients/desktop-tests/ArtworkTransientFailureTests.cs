using System.Collections.Concurrent;
using System.Text;
using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// "There is no cover" and "I could not get the cover right now" are different
/// answers, and the cache is only allowed to remember the first.
///
/// It remembers failures so it does not re-ask for art that does not exist, and
/// nothing ever removes a key from that set. So a failure recorded for the wrong
/// reason is permanent: the cover is gone until the process restarts. That is
/// exactly what happened when attaching a Plex server grew slower — the first
/// wave of tiles asked before there was a backend to ask, every one was written
/// off, and the whole library rendered as letter placeholders.
/// </summary>
public class ArtworkTransientFailureTests
{
    private static ArtworkRef Ref(string key, int size = 100) => new("srv", key, size);

    private static byte[]? Identity(byte[] bytes) => bytes;

    [Fact]
    public async Task ATransientFailureIsRetriedOnTheNextRequest()
    {
        var attempts = 0;
        using var cache = new ArtworkCache<byte[]>(
            fetch: (r, ct) =>
            {
                attempts++;
                // First ask fails the way an unattached server fails; the second
                // succeeds, as it would once attach finished.
                if (attempts == 1) throw new ArtworkUnavailableException("no server attached yet");
                return Task.FromResult<byte[]?>(Encoding.UTF8.GetBytes("cover"));
            },
            decode: Identity,
            diskDirectory: null);

        var first = await cache.GetAsync(Ref("a"));
        var second = await cache.GetAsync(Ref("a"));

        Assert.Null(first);
        Assert.NotNull(second);
        Assert.Equal(2, attempts);
    }

    [Fact]
    public async Task AnAbsentCoverIsRememberedAndNotAskedForAgain()
    {
        var attempts = 0;
        using var cache = new ArtworkCache<byte[]>(
            fetch: (r, ct) =>
            {
                attempts++;
                // Null is the backend answering "there is nothing here" — the one
                // failure worth remembering.
                return Task.FromResult<byte[]?>(null);
            },
            decode: Identity,
            diskDirectory: null);

        Assert.Null(await cache.GetAsync(Ref("a")));
        Assert.Null(await cache.GetAsync(Ref("a")));

        Assert.Equal(1, attempts);
    }

    [Fact]
    public async Task ForgettingFailuresGivesAnAbsentCoverAnotherChance()
    {
        var attempts = 0;
        using var cache = new ArtworkCache<byte[]>(
            fetch: (r, ct) =>
            {
                attempts++;
                return Task.FromResult<byte[]?>(
                    attempts == 1 ? null : Encoding.UTF8.GetBytes("cover"));
            },
            decode: Identity,
            diskDirectory: null);

        Assert.Null(await cache.GetAsync(Ref("a")));
        Assert.Null(await cache.GetAsync(Ref("a")));   // remembered, not re-asked
        Assert.Equal(1, attempts);

        // What attaching a server does.
        cache.ForgetFailures();

        Assert.NotNull(await cache.GetAsync(Ref("a")));
        Assert.Equal(2, attempts);
    }

    /// <summary>
    /// A transient failure must not be mistaken for a decode failure either:
    /// undecodable bytes really are a dead end for that key and stay remembered.
    /// </summary>
    [Fact]
    public async Task UndecodableBytesAreStillRemembered()
    {
        var attempts = 0;
        using var cache = new ArtworkCache<byte[]>(
            fetch: (r, ct) =>
            {
                attempts++;
                return Task.FromResult<byte[]?>(Encoding.UTF8.GetBytes("junk"));
            },
            decode: _ => null,
            diskDirectory: null);

        Assert.Null(await cache.GetAsync(Ref("a")));
        Assert.Null(await cache.GetAsync(Ref("a")));

        Assert.Equal(1, attempts);
    }
}

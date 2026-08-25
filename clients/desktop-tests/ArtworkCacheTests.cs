using System.Collections.Concurrent;
using System.Text;
using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Exercises the real caching engine with an injected fetch, so every property
/// the artwork pipeline leans on — memory bound, disk reuse, coalescing, negative
/// caching, concurrency cap — is verified with no network and no display.
///
/// The decoded product is a plain <c>byte[]</c>: nothing here needs a bitmap, and
/// using bytes keeps the tests in the same Avalonia-free world the cache lives in.
/// </summary>
public class ArtworkCacheTests
{
    private static ArtworkRef Ref(string key, int size = 100) => new("srv", key, size);

    private static byte[] BytesFor(string key) => Encoding.UTF8.GetBytes("img-" + key);

    private static byte[]? Identity(byte[] bytes) => bytes;

    [Fact]
    public async Task MemoryHit_DoesNotFetchTwice()
    {
        var calls = new ConcurrentDictionary<string, int>();
        using var cache = new ArtworkCache<byte[]>(
            fetch: (r, ct) =>
            {
                calls.AddOrUpdate(r.ArtworkKey, 1, (_, n) => n + 1);
                return Task.FromResult<byte[]?>(BytesFor(r.ArtworkKey));
            },
            decode: Identity,
            diskDirectory: null);

        var first = await cache.GetAsync(Ref("a"));
        var second = await cache.GetAsync(Ref("a"));

        Assert.NotNull(first);
        Assert.Equal(first, second);
        Assert.Equal(1, calls["a"]);
    }

    [Fact]
    public async Task Eviction_BoundsMemory_AndEvictedKeyRefetches()
    {
        var calls = new ConcurrentDictionary<string, int>();
        using var cache = new ArtworkCache<byte[]>(
            fetch: (r, ct) =>
            {
                calls.AddOrUpdate(r.ArtworkKey, 1, (_, n) => n + 1);
                return Task.FromResult<byte[]?>(BytesFor(r.ArtworkKey));
            },
            decode: Identity,
            memoryCapacity: 2,
            diskDirectory: null); // no disk, so an evicted key must hit the network again

        await cache.GetAsync(Ref("k1"));
        await cache.GetAsync(Ref("k2"));
        await cache.GetAsync(Ref("k3")); // evicts k1, the coldest

        Assert.Equal(2, cache.MemoryCount); // the bound holds
        Assert.Equal(1, calls["k1"]);

        var hit = await cache.GetAsync(Ref("k3")); // still resident: no new fetch
        Assert.NotNull(hit);
        Assert.Equal(1, calls["k3"]);

        await cache.GetAsync(Ref("k1")); // evicted earlier: must fetch again
        Assert.Equal(2, calls["k1"]);
        Assert.Equal(2, cache.MemoryCount); // still bounded after the refetch
    }

    [Fact]
    public async Task FailedKey_IsNegativeCached_AndNotRetried()
    {
        var calls = new ConcurrentDictionary<string, int>();
        using var cache = new ArtworkCache<byte[]>(
            fetch: (r, ct) =>
            {
                calls.AddOrUpdate(r.ArtworkKey, 1, (_, n) => n + 1);
                return Task.FromResult<byte[]?>(null); // "no art here" — the normal failure
            },
            decode: Identity,
            diskDirectory: null);

        var first = await cache.GetAsync(Ref("dead"));
        var second = await cache.GetAsync(Ref("dead"));

        Assert.Null(first);
        Assert.Null(second);
        Assert.Equal(1, calls["dead"]); // the dead server was asked exactly once
    }

    [Fact]
    public async Task ConcurrentRequestsForSameKey_ShareOneFetch()
    {
        var calls = 0;
        var gate = new TaskCompletionSource<byte[]?>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var cache = new ArtworkCache<byte[]>(
            fetch: (r, ct) =>
            {
                Interlocked.Increment(ref calls);
                return gate.Task; // block until the test releases it
            },
            decode: Identity,
            diskDirectory: null);

        // Both calls register against the same in-flight production before either completes.
        var t1 = cache.GetAsync(Ref("shared"));
        var t2 = cache.GetAsync(Ref("shared"));

        gate.SetResult(BytesFor("shared"));
        var r1 = await t1;
        var r2 = await t2;

        Assert.NotNull(r1);
        Assert.Equal(r1, r2);
        Assert.Equal(1, calls); // forty song rows sharing an album download it once
    }

    [Fact]
    public async Task Concurrency_IsCapped()
    {
        const int cap = 2;
        var sync = new object();
        int active = 0, peak = 0;
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        using var cache = new ArtworkCache<byte[]>(
            fetch: async (r, ct) =>
            {
                lock (sync) { active++; peak = Math.Max(peak, active); }
                await gate.Task.ConfigureAwait(false);
                lock (sync) { active--; }
                return BytesFor(r.ArtworkKey);
            },
            decode: Identity,
            maxConcurrency: cap,
            diskDirectory: null);

        // Five distinct covers asked for at once; only `cap` may be in flight.
        var tasks = Enumerable.Range(0, 5)
            .Select(i => cache.GetAsync(Ref("key" + i)))
            .ToArray();

        var reached = SpinWait.SpinUntil(() => { lock (sync) return active == cap; }, TimeSpan.FromSeconds(5));
        Assert.True(reached, "expected the concurrency cap to be saturated");
        lock (sync) Assert.Equal(cap, peak); // never more than the cap at once

        gate.SetResult();
        var results = await Task.WhenAll(tasks);

        Assert.All(results, r => Assert.NotNull(r));
        lock (sync) Assert.Equal(cap, peak); // the waiters draining did not exceed it either
    }

    [Fact]
    public async Task DiskCache_IsReusedByAFreshInstance()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "arttest_" + Guid.NewGuid().ToString("N"));
        try
        {
            var firstCalls = 0;
            byte[]? warmed;
            using (var warm = new ArtworkCache<byte[]>(
                fetch: (r, ct) => { Interlocked.Increment(ref firstCalls); return Task.FromResult<byte[]?>(BytesFor(r.ArtworkKey)); },
                decode: Identity,
                diskDirectory: dir))
            {
                warmed = await warm.GetAsync(Ref("persist"));
            }

            Assert.NotNull(warmed);
            Assert.Equal(1, firstCalls);

            var secondCalls = 0;
            using var cold = new ArtworkCache<byte[]>(
                fetch: (r, ct) => { Interlocked.Increment(ref secondCalls); return Task.FromResult<byte[]?>(BytesFor(r.ArtworkKey)); },
                decode: Identity,
                diskDirectory: dir);

            var fromDisk = await cold.GetAsync(Ref("persist"));

            Assert.NotNull(fromDisk);
            Assert.Equal(warmed, fromDisk); // same bytes came back
            Assert.Equal(0, secondCalls);   // a restart did not re-download it
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }
}

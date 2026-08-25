using System.Security.Cryptography;
using System.Text;

namespace Mozz.Desktop.Core;

/// <summary>
/// One piece of artwork to fetch: whose server, which key, at what pixel size.
///
/// A value type so it is a cheap, correct dictionary key — two requests for the
/// same cover at the same size are the same request. The size is part of the
/// identity on purpose: the album wall draws at 176 and the player bar at 56,
/// and asking the server for each at its own resolution is the whole point of
/// requesting art at the displayed size rather than one fixed large one.
/// </summary>
public readonly record struct ArtworkRef(string ServerId, string ArtworkKey, int Size)
{
    /// <summary>Stable string form, used to key the memory and disk caches.</summary>
    public string Key => $"{ServerId}\u0000{ArtworkKey}\u0000{Size}";
}

/// <summary>
/// The thing that keeps a wall of album art from becoming a wall of HTTP
/// requests.
///
/// A real self-hosted library is not a few hundred covers — Mozz's benchmark is
/// 12,500 albums — and it is browsed by scrolling, which means the same cover
/// leaves the screen and comes back constantly. Three properties follow from
/// that and are the reason this class exists rather than a
/// <c>Dictionary&lt;string, Bitmap&gt;</c>:
///
/// <list type="bullet">
///   <item>The memory cache is <b>bounded</b>. A decoded 352×352 cover is about
///   half a megabyte; holding every one would be well over a gigabyte. So the
///   most-recently-used <see cref="MemoryCount"/> stay decoded and the rest are
///   dropped — never <i>disposed</i>, because an evicted bitmap may still be the
///   <c>Source</c> of a visual that is mid-render, and the garbage collector
///   reclaims its native memory safely once nothing points at it.</item>
///   <item>Every fetch is written to <b>disk</b>, so restarting the app does not
///   re-download the library. A cold start reads covers back from there at local
///   speed.</item>
///   <item>Concurrency is <b>capped</b>. Scrolling can ask for a hundred covers
///   in a frame; opening a hundred sockets to satisfy them would starve
///   everything else. A small semaphore lets a handful through at a time and the
///   rest wait their turn — which they can afford to, being off-screen.</item>
/// </list>
///
/// Two more behaviours matter as much as those. Requests for the same key are
/// <b>coalesced</b>: if a cover is already being fetched, a second ask joins the
/// first rather than starting its own, so a song list where forty rows share one
/// album downloads that cover once. And a failure is <b>remembered</b> — a
/// missing or unreachable cover is recorded and not retried for the life of the
/// session, because a dead server must not be asked the same dead question on
/// every scroll pass. Failure here is ordinary: Plex and Jellyfin routinely have
/// no art for an item.
///
/// It is deliberately free of any UI framework. Decoding bytes into whatever the
/// UI draws is the one thing it does not do itself — that is the injected
/// <c>decode</c> — which keeps the cache, and all of the logic above, testable
/// with no display and no network.
/// </summary>
/// <typeparam name="T">
/// The decoded product the UI holds — a bitmap in the app, anything in a test.
/// </typeparam>
public sealed class ArtworkCache<T> : IDisposable where T : class
{
    private sealed class Node
    {
        public required string Key;
        public required T Value;
    }

    private readonly object _gate = new();
    private readonly Dictionary<string, LinkedListNode<Node>> _memory = new();
    private readonly LinkedList<Node> _recency = new();
    private readonly HashSet<string> _negative = new();
    private readonly Dictionary<string, Task<T?>> _inflight = new();

    private readonly SemaphoreSlim _concurrency;
    private readonly CancellationTokenSource _life = new();

    private readonly int _capacity;
    private readonly string? _diskDirectory;
    private readonly Func<ArtworkRef, CancellationToken, Task<byte[]?>> _fetch;
    private readonly Func<byte[], T?> _decode;

    /// <param name="fetch">
    /// Produce the raw encoded bytes for a request — in the app, resolve the URL
    /// through the core and download it. Returns null for "no such art", which is
    /// a normal answer and gets negative-cached.
    /// </param>
    /// <param name="decode">
    /// Turn encoded bytes into the drawn product. Returns null for undecodable
    /// bytes, treated as a failure.
    /// </param>
    /// <param name="memoryCapacity">
    /// How many decoded items to keep. This is the memory bound; past it the
    /// least-recently-used are evicted.
    /// </param>
    /// <param name="maxConcurrency">How many fetches may be in flight at once.</param>
    /// <param name="diskDirectory">
    /// Where to persist encoded bytes across restarts, or null for memory-only
    /// (which is what the cache tests use to force re-fetches).
    /// </param>
    public ArtworkCache(
        Func<ArtworkRef, CancellationToken, Task<byte[]?>> fetch,
        Func<byte[], T?> decode,
        int memoryCapacity = 384,
        int maxConcurrency = 6,
        string? diskDirectory = null)
    {
        _fetch = fetch;
        _decode = decode;
        _capacity = Math.Max(1, memoryCapacity);
        _concurrency = new SemaphoreSlim(Math.Max(1, maxConcurrency));
        _diskDirectory = diskDirectory;

        if (_diskDirectory is not null)
        {
            try { Directory.CreateDirectory(_diskDirectory); }
            catch { _diskDirectory = null; } // a cache we cannot persist is still a cache
        }
    }

    /// <summary>How many decoded items are currently held. Never exceeds capacity.</summary>
    public int MemoryCount
    {
        get { lock (_gate) return _memory.Count; }
    }

    /// <summary>
    /// The decoded artwork for a request, or null if there is none or it could
    /// not be had. Cheap and synchronous on a memory hit; otherwise joins or
    /// starts a single shared fetch.
    ///
    /// <paramref name="token"/> only stops <i>this caller</i> waiting — a control
    /// that scrolled away and cancelled does not cancel the download, because the
    /// cover it started is exactly what the next viewer of that row will want.
    /// </summary>
    public async Task<T?> GetAsync(ArtworkRef request, CancellationToken token = default)
    {
        var key = request.Key;
        Task<T?> production;

        lock (_gate)
        {
            if (_negative.Contains(key)) return null;

            if (_memory.TryGetValue(key, out var node))
            {
                Touch(node);
                return node.Value.Value;
            }

            if (!_inflight.TryGetValue(key, out production!))
            {
                // Task.Run so the disk read, download and decode never touch the
                // caller's thread — GetAsync can be called from the UI thread.
                production = Task.Run(() => ProduceAsync(request, key));
                _inflight[key] = production;
            }
        }

        // WaitAsync rather than a bare await so the caller's cancellation is
        // honoured without disturbing the shared production every other caller
        // is also awaiting.
        return await production.WaitAsync(token).ConfigureAwait(false);
    }

    private async Task<T?> ProduceAsync(ArtworkRef request, string key)
    {
        var path = DiskPath(key);
        var fromDisk = false;
        try
        {
            byte[]? bytes = null;

            if (path is not null && File.Exists(path))
            {
                try
                {
                    bytes = await File.ReadAllBytesAsync(path, _life.Token).ConfigureAwait(false);
                    fromDisk = bytes.Length > 0;
                    if (!fromDisk) bytes = null;
                }
                catch (OperationCanceledException) { throw; }
                catch { bytes = null; } // unreadable cache file: fall through to the network
            }

            if (bytes is null)
            {
                await _concurrency.WaitAsync(_life.Token).ConfigureAwait(false);
                try
                {
                    bytes = await _fetch(request, _life.Token).ConfigureAwait(false);
                }
                finally
                {
                    _concurrency.Release();
                }

                if (bytes is not { Length: > 0 })
                {
                    Fail(key);
                    return null;
                }

                if (path is not null) TryWriteDisk(path, bytes);
            }

            var decoded = _decode(bytes);
            if (decoded is null)
            {
                // Bad bytes. If they came from disk the file is corrupt — drop it
                // so a future run can try the network again — then give up for now.
                if (fromDisk && path is not null) TryDeleteDisk(path);
                Fail(key);
                return null;
            }

            Store(key, decoded);
            return decoded;
        }
        catch (OperationCanceledException)
        {
            // Only the cache being disposed cancels _life; that is a shutdown, not
            // a missing cover, so it must not be negative-cached.
            lock (_gate) _inflight.Remove(key);
            return null;
        }
        catch
        {
            Fail(key);
            return null;
        }
    }

    private void Touch(LinkedListNode<Node> node)
    {
        // Caller holds _gate.
        _recency.Remove(node);
        _recency.AddFirst(node);
    }

    private void Store(string key, T value)
    {
        lock (_gate)
        {
            _inflight.Remove(key);

            if (_memory.TryGetValue(key, out var existing))
            {
                existing.Value.Value = value;
                Touch(existing);
                return;
            }

            var node = new LinkedListNode<Node>(new Node { Key = key, Value = value });
            _recency.AddFirst(node);
            _memory[key] = node;

            // Evict the coldest until we are back within bound. Evicted bitmaps are
            // deliberately not disposed: one may still be an on-screen Source, and
            // the GC frees it once no visual references it.
            while (_memory.Count > _capacity)
            {
                var tail = _recency.Last;
                if (tail is null) break;
                _recency.RemoveLast();
                _memory.Remove(tail.Value.Key);
            }
        }
    }

    private void Fail(string key)
    {
        lock (_gate)
        {
            _negative.Add(key);
            _inflight.Remove(key);
        }
    }

    private string? DiskPath(string key)
    {
        if (_diskDirectory is null) return null;
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)));
        return Path.Combine(_diskDirectory, hash + ".img");
    }

    private static void TryWriteDisk(string path, byte[] bytes)
    {
        try
        {
            // Write-then-rename so a crash mid-write cannot leave a truncated file
            // that would decode to garbage on the next run.
            var temp = path + ".tmp";
            File.WriteAllBytes(temp, bytes);
            File.Move(temp, path, overwrite: true);
        }
        catch
        {
            // A cover that failed to cache to disk is not worth surfacing; it will
            // simply be fetched again next session.
        }
    }

    private static void TryDeleteDisk(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { /* best effort */ }
    }

    public void Dispose()
    {
        _life.Cancel();
        _life.Dispose();
        _concurrency.Dispose();
    }
}

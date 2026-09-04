using Avalonia.Media.Imaging;

namespace Mozz.Desktop.Core;

/// <summary>
/// The app's one artwork pipeline: request → URL → bytes → bitmap, cached.
///
/// It exists so the <see cref="Mozz.Desktop.Controls.ArtworkImage"/> tiles — which
/// are created by data templates and so cannot be handed dependencies — have a
/// single shared cache, HTTP client and core connection to draw from, reached
/// through the ambient <see cref="Current"/>. That is a deliberate compromise:
/// XAML-instantiated controls have no constructor to inject into, and one process-
/// wide service is far less error-prone than teaching every template to thread a
/// dependency down to its leaves.
///
/// The pipeline itself is two injected steps wrapped around <see cref="ArtworkCache{T}"/>:
/// resolving and downloading a cover, and decoding it. Both are written to fail
/// quietly and return "no art", because for artwork that is a routine answer —
/// the server may simply not have a cover — and the cache turns a routine failure
/// into a remembered one so a dead URL is asked for exactly once.
/// </summary>
public sealed class ArtworkService : IDisposable
{
    public const string DirectUrlNamespace = "__direct-url__";

    /// <summary>
    /// The process-wide instance the tiles read. Null in the designer and before
    /// the main view model is constructed, in which case tiles just draw their
    /// gradient fallback.
    /// </summary>
    public static ArtworkService? Current { get; set; }

    /// <summary>
    /// Raised the first time artwork fails for a reason worth telling someone
    /// about, with a sentence fit for the status bar.
    ///
    /// Covers failing used to be completely silent — not surfaced, not logged —
    /// so a library that rendered every tile as a letter placeholder looked
    /// identical whether the server had no art, the network was refusing the
    /// connection, or the app had simply not attached yet. Hours were spent on
    /// that ambiguity. One sentence would have removed it.
    ///
    /// Once, not per tile: five thousand albums failing for the same reason is
    /// still one thing the user needs to know.
    /// </summary>
    public event Action<string>? ArtworkFailed
    {
        add => _reporter.Reported += value;
        remove => _reporter.Reported -= value;
    }

    private readonly FailureReporter _reporter = new();

    private void Report(string reason) => _reporter.Report(reason);

    /// <summary>
    /// Forget which failure has already been reported, so a problem that
    /// survives a server attaching is announced rather than suppressed because
    /// it was mentioned before there was a server to mention it about.
    /// </summary>
    public void ResetFailureReport() => _reporter.Reset();

    /// <summary>
    /// Raised when artwork starts working again after a spell of failing.
    ///
    /// Static because the tiles that need to hear it are created and destroyed
    /// constantly by list virtualization and have no handle on the service.
    /// </summary>
    public static event Action? ArtworkRecovered;

    private readonly RetrySchedule _retry = new();
    private ArtworkRef? _lastTransientFailure;
    private int _probing;

    /// <summary>
    /// Keep quietly retrying one cover that failed, and announce it the moment
    /// one works.
    ///
    /// macOS only prompts for local network access once the app actually tries,
    /// and granting it tells the app nothing. By then every visible tile has
    /// already failed and drawn its placeholder, and a tile never asks twice -
    /// so the covers stayed blank until the user happened to navigate away and
    /// back. Nobody should have to discover that.
    ///
    /// One probe, not one per tile: the question "is the server reachable" has
    /// the same answer for all five thousand of them.
    /// </summary>
    private void BeginRecoveryProbe(ArtworkRef failed)
    {
        _lastTransientFailure = failed;
        if (Interlocked.Exchange(ref _probing, 1) == 1) return;

        _ = Task.Run(async () =>
        {
            try
            {
                while (true)
                {
                    await Task.Delay(_retry.Next()).ConfigureAwait(false);

                    var probe = _lastTransientFailure;
                    if (probe is null) return;

                    try
                    {
                        await FetchAsync(probe.Value, CancellationToken.None).ConfigureAwait(false);
                    }
                    catch (ArtworkUnavailableException)
                    {
                        continue;   // still broken; wait longer and ask again
                    }
                    catch (Exception)
                    {
                        continue;
                    }

                    // A cover came back. Anything written off while the server
                    // was unreachable deserves another chance, and the tiles
                    // showing placeholders need to be told to ask again.
                    _cache.ForgetFailures();
                    _directUrlCache.ForgetFailures();
                    _reporter.Reset();
                    _retry.Reset();
                    _lastTransientFailure = null;
                    ArtworkRecovered?.Invoke();
                    return;
                }
            }
            finally
            {
                Interlocked.Exchange(ref _probing, 0);
            }
        });
    }

    private readonly MozzServer _server;
    private readonly HttpClient _http;
    private readonly ArtworkCache<Bitmap> _cache;
    private readonly ArtworkCache<Bitmap> _directUrlCache;

    public ArtworkService(MozzServer server, string? diskDirectory)
    {
        _server = server;
        _http = new HttpClient
        {
            // A cover is not worth waiting on forever; a slow one should fail and
            // fall back rather than pin a fetch slot and starve the rest.
            Timeout = TimeSpan.FromSeconds(20),
        };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozz/1.0");

        _cache = new ArtworkCache<Bitmap>(
            fetch: FetchAsync,
            decode: Decode,
            memoryCapacity: 384,
            maxConcurrency: 6,
            diskDirectory: diskDirectory);
        _directUrlCache = new ArtworkCache<Bitmap>(
            fetch: FetchDirectUrlAsync,
            decode: Decode,
            memoryCapacity: 64,
            maxConcurrency: 3,
            diskDirectory: diskDirectory is null ? null : Path.Combine(diskDirectory, "direct-url"));
    }

    /// <summary>
    /// Build the service against the app's support directory, and publish it as
    /// <see cref="Current"/>.
    /// </summary>
    public static ArtworkService Install(MozzServer server)
    {
        var directory = Path.Combine(AppPaths.SupportDirectory, "artwork");
        var service = new ArtworkService(server, directory);
        Current = service;
        return service;
    }

    /// <summary>The decoded cover for a request, or null when there is none.</summary>
    public Task<Bitmap?> LoadAsync(ArtworkRef request, CancellationToken token)
        => _cache.GetAsync(request, token);

    /// <summary>
    /// Load an already-resolved image URL through the same bounded, recycling-safe
    /// cache as server artwork. Account avatars arrive this way: they are not
    /// catalog artwork keys and must not be sent through the artworkURL command.
    /// </summary>
    public Task<Bitmap?> LoadDirectUrlAsync(ArtworkRef request, CancellationToken token)
        => _directUrlCache.GetAsync(request, token);

    /// <summary>
    /// Forget every remembered artwork failure, on both caches.
    ///
    /// See <see cref="ArtworkUnavailableException"/>: a failure recorded while
    /// no server was attached is not evidence that a cover is missing.
    /// </summary>
    public void ForgetFailures()
    {
        _cache.ForgetFailures();
        _directUrlCache.ForgetFailures();
    }

    private async Task<byte[]?> FetchAsync(ArtworkRef request, CancellationToken token)
    {
        string? url;
        try
        {
            url = await _server
                .ArtworkUrlAsync(request.ServerId, request.ArtworkKey, request.Size, token)
                .ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // The core resolves the key against the attached backend, so this
            // throws while a server is still attaching — which says nothing
            // about whether the cover exists. Returning null here would have the
            // cache write it off for the rest of the session.
            Report(ex.Message.Contains("attached", StringComparison.OrdinalIgnoreCase)
                ? "Waiting for the server before album art can load."
                : $"Album art unavailable: {ex.Message}");
            BeginRecoveryProbe(request);
            throw new ArtworkUnavailableException(
                $"could not resolve artwork for {request.ArtworkKey}", ex);
        }

        // A resolved-but-empty URL is the one honest "there is no art here":
        // the backend was asked and had nothing. That is worth remembering.
        if (string.IsNullOrEmpty(url)) return null;

        try
        {
            using var response = await _http
                .GetAsync(url, HttpCompletionOption.ResponseHeadersRead, token)
                .ConfigureAwait(false);

            // A 404 is the server saying this art does not exist; anything else
            // — unauthorised, unavailable, gateway trouble — is about the moment
            // rather than the artwork, and should be retried later.
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
            if (!response.IsSuccessStatusCode)
            {
                throw new ArtworkUnavailableException(
                    $"artwork fetch returned {(int)response.StatusCode}");
            }

            return await response.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
        }
        catch (ArtworkUnavailableException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            // "No route to host" for a server that curl and ping both reach is
            // almost always macOS refusing local network access to this app
            // rather than anything about the network. Say so, because the raw
            // socket error sends people to look at their router.
            Report(ex is HttpRequestException { HttpRequestError: HttpRequestError.ConnectionError }
                ? "Can't reach your server for album art. If it is on your local network, "
                  + "check System Settings › Privacy & Security › Local Network and allow Mozz."
                : $"Album art unavailable: {ex.Message}");
            BeginRecoveryProbe(request);
            throw new ArtworkUnavailableException("artwork fetch failed", ex);
        }
    }

    private async Task<byte[]?> FetchDirectUrlAsync(ArtworkRef request, CancellationToken token)
    {
        if (!Uri.TryCreate(request.ArtworkKey, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme is not ("http" or "https")) return null;

        try
        {
            using var response = await _http
                .GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, token)
                .ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            return await response.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
    }

    private static Bitmap? Decode(byte[] bytes)
    {
        try
        {
            using var stream = new MemoryStream(bytes, writable: false);
            return new Bitmap(stream);
        }
        catch
        {
            // Not an image, or a format the decoder does not know. Fall back.
            return null;
        }
    }

    public void Dispose()
    {
        if (ReferenceEquals(Current, this)) Current = null;
        _cache.Dispose();
        _directUrlCache.Dispose();
        _http.Dispose();
    }
}

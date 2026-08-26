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

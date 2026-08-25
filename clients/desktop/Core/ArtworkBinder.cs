namespace Mozz.Desktop.Core;

/// <summary>
/// The guard that stops a recycled tile from showing the wrong cover.
///
/// The album and artist walls are virtualized: their tile containers are a small
/// pool that is <i>reused</i> as you scroll, so the same visual that showed album
/// A a moment ago is handed album Z next. Artwork loads asynchronously, and the
/// two facts collide badly — a fetch started for A can finish after its tile has
/// become Z, and naively assigning the result paints A's cover onto Z. On a fast
/// scroll that is not a rare race; it is most of them, and it reads as the grid
/// randomly mislabelling records.
///
/// This isolates the fix in one place. Every rebind bumps a generation counter
/// and cancels the previous load; a load may only apply its result if it is still
/// the current generation when it completes. A superseded fetch is discarded
/// rather than shown. Rebinding also clears the tile to its fallback immediately,
/// so a reused container never displays the previous item's cover while the new
/// one loads.
///
/// The generation counter, rather than comparing keys, is what makes an
/// A→B→A rebind correct: the first A's load belongs to an older generation than
/// the second A's and is dropped, and the second A reloads (a cache hit). It is
/// UI-framework-free on purpose — <c>apply</c> is injected — so the hazard it
/// guards against can be reproduced and tested without a window.
/// </summary>
/// <typeparam name="T">The decoded product to hand back, a bitmap in the app.</typeparam>
public sealed class ArtworkBinder<T> : IDisposable where T : class
{
    private readonly Func<ArtworkRef, CancellationToken, Task<T?>> _load;
    private readonly Action<T?> _apply;
    private readonly Action<Action> _post;

    private readonly object _gate = new();
    private ArtworkRef? _current;
    private bool _hasCurrent;
    private int _generation;
    private CancellationTokenSource? _cts;

    /// <param name="load">Fetch the decoded artwork for a request.</param>
    /// <param name="apply">
    /// Show a result: a value to display it, null to fall back. Always invoked
    /// through <paramref name="post"/>.
    /// </param>
    /// <param name="post">
    /// Marshal <paramref name="apply"/> to the thread that may touch the UI. The
    /// app passes the dispatcher; tests pass an inline runner so completion is
    /// deterministic.
    /// </param>
    public ArtworkBinder(
        Func<ArtworkRef, CancellationToken, Task<T?>> load,
        Action<T?> apply,
        Action<Action>? post = null)
    {
        _load = load;
        _apply = apply;
        _post = post ?? (action => action());
    }

    /// <summary>
    /// Point this tile at a new request, or at nothing. Cancels any load still in
    /// flight for the previous request, shows the fallback at once, and starts the
    /// new load if there is one. A repeat bind to the identical request is a no-op,
    /// so the redundant property churn of recycling does not restart a good load.
    /// </summary>
    public void Bind(ArtworkRef? request)
    {
        int generation;
        CancellationToken token;

        lock (_gate)
        {
            if (_hasCurrent && Nullable.Equals(_current, request)) return;

            _current = request;
            _hasCurrent = true;

            _cts?.Cancel();
            _cts?.Dispose();
            _cts = null;

            generation = ++_generation;

            if (request is null)
            {
                _post(() => ApplyIfCurrent(null, generation));
                return;
            }

            _cts = new CancellationTokenSource();
            token = _cts.Token;
        }

        // Clear to the fallback while the new cover loads, so a recycled tile does
        // not keep showing the old item's art.
        _post(() => ApplyIfCurrent(null, generation));

        _ = LoadAsync(request.Value, generation, token);
    }

    private async Task LoadAsync(ArtworkRef request, int generation, CancellationToken token)
    {
        try
        {
            var result = await _load(request, token).ConfigureAwait(false);
            if (result is null) return; // leave the fallback showing
            if (token.IsCancellationRequested) return;
            if (Volatile.Read(ref _generation) != generation) return; // superseded by a rebind

            _post(() => ApplyIfCurrent(result, generation));
        }
        catch (OperationCanceledException)
        {
            // Rebound out from under this load; the newer bind owns the tile now.
        }
        catch
        {
            // A failed load leaves the fallback in place — nothing to show is the
            // honest outcome, not an error to surface on a tile.
        }
    }

    private void ApplyIfCurrent(T? value, int generation)
    {
        // Final check on the UI thread: a rebind may have landed between the load
        // completing and this running.
        if (Volatile.Read(ref _generation) != generation) return;
        _apply(value);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _cts?.Cancel();
            _cts?.Dispose();
            _cts = null;
            _generation++;
        }
    }
}

namespace Mozz.Desktop.Core;

/// <summary>
/// Says a thing once, not once per occurrence.
///
/// Album covers used to fail completely silently — nothing in the UI, nothing
/// in a log — so a library rendering every tile as a letter placeholder looked
/// identical whether the server genuinely had no art, the network was refusing
/// the connection, or the app had not attached to a server yet. Those call for
/// different responses from whoever is looking at the screen, and hours went
/// into telling them apart by hand when one sentence would have done it.
///
/// The reason it stayed silent is the obvious objection to fixing it: five
/// thousand albums failing means five thousand messages. So collapse them.
/// A repeated reason is dropped; a genuinely different one still gets through.
///
/// Deliberately here rather than inside the artwork service. This is a policy
/// about how often to speak, it has nothing to do with images, and the artwork
/// service needs Avalonia — which would put it out of reach of these tests.
/// </summary>
public sealed class FailureReporter
{
    private readonly object _gate = new();
    private string? _lastReported;

    /// <summary>Raised only for a reason that is not already the current one.</summary>
    public event Action<string>? Reported;

    public void Report(string reason)
    {
        lock (_gate)
        {
            if (_lastReported == reason) return;
            _lastReported = reason;
        }

        // Outside the lock: a handler that posts to the UI thread, or throws,
        // must not be able to hold up whatever else is failing at the time.
        Reported?.Invoke(reason);
    }

    /// <summary>
    /// Forget what was last said, so an unchanged reason can be said again.
    ///
    /// Called when a server attaches, because that is the moment the previous
    /// complaint might have stopped being true. Without it, a problem that
    /// survives the attach would stay silent on the grounds that it had already
    /// been mentioned — before there was any server to mention it about.
    /// </summary>
    public void Reset()
    {
        lock (_gate) _lastReported = null;
    }
}

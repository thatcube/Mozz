namespace Mozz.Desktop.Core;

/// <summary>
/// How long to wait before asking again after something failed for a reason
/// that might stop being true.
///
/// The case this exists for: macOS only prompts for local network access once
/// the app actually tries, and granting it does not notify the app. Album art
/// had already failed for every visible tile by then, and a tile that has drawn
/// its letter placeholder never asks a second time - so the covers stayed blank
/// until the user navigated away and back. Nobody should have to know that.
///
/// So something has to keep asking. Not eagerly: a server that is genuinely
/// down should not be hammered, and this runs while the user is doing nothing.
/// Doubling from a short first wait means a permission granted five seconds in
/// is noticed almost immediately, while a server that is off for an hour is
/// asked about twice a minute rather than constantly.
/// </summary>
public sealed class RetrySchedule
{
    private readonly TimeSpan _first;
    private readonly TimeSpan _ceiling;
    private int _attempt;

    public RetrySchedule(TimeSpan? first = null, TimeSpan? ceiling = null)
    {
        _first = first ?? TimeSpan.FromSeconds(2);
        _ceiling = ceiling ?? TimeSpan.FromSeconds(30);
    }

    /// <summary>The wait before the next attempt, doubling up to the ceiling.</summary>
    public TimeSpan Next()
    {
        // Cap the exponent before shifting rather than after: at attempt 62 the
        // doubling would overflow into a negative delay, and a schedule that is
        // meant to slow down would start firing instantly forever.
        var doublings = Math.Min(_attempt, 20);
        var ticks = _first.Ticks * (1L << doublings);
        _attempt++;
        return ticks >= _ceiling.Ticks ? _ceiling : TimeSpan.FromTicks(ticks);
    }

    /// <summary>Start over, after something succeeded.</summary>
    public void Reset() => _attempt = 0;
}

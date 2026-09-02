using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

/// <summary>
/// One line in the Up Next panel. Carries the slot it occupies in the current
/// playback order rather than the track alone, because a queue can legitimately
/// hold the same track twice — a mix that repeats a song, an album played after
/// itself — and clicking the second copy has to play the second copy.
/// </summary>
public sealed record QueueRow(int OrderIndex, Track Track, bool IsCurrent)
{
    /// <summary>The "3." in front of the title, 1-based over the whole queue.</summary>
    public string Ordinal => (OrderIndex + 1).ToString();
}

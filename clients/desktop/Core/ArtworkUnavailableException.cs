namespace Mozz.Desktop.Core;

/// <summary>
/// "Not right now" as distinct from "not at all".
///
/// The artwork cache remembers failures so it does not keep re-asking for a
/// cover that does not exist. That is only correct when the failure is about
/// the artwork. A server that has not finished attaching yet, or a request that
/// timed out, says nothing about whether the cover exists — and recording it
/// means the cover never appears again for the life of the process, because
/// nothing ever removes a key from the negative set.
///
/// This is what made every cover vanish. Attaching grew slower once Plex
/// servers started being probed for reachability, so the first wave of tiles
/// asked before there was a backend to ask, got "needs an attached serverId",
/// and every one of them was written off permanently.
/// </summary>
public sealed class ArtworkUnavailableException : Exception
{
    public ArtworkUnavailableException(string message) : base(message) { }

    public ArtworkUnavailableException(string message, Exception inner) : base(message, inner) { }
}

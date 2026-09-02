namespace Mozz.Desktop.Core;

/// <summary>How the queue behaves when a track, or the queue, runs out.</summary>
public enum RepeatMode
{
    /// <summary>Advance to the next track; stop at the end of the queue.</summary>
    Off,
    /// <summary>Advance to the next track; wrap to the start at the end of the queue.</summary>
    All,
    /// <summary>Repeat the current track indefinitely.</summary>
    One,
}

/// <summary>
/// What plays next. A value-ish, engine-free model of the queue, so "next"
/// is decided by app logic and the audio engine only ever knows the current
/// track and the one to stitch in after it.
///
/// The model is the one the phone uses (<c>PlayQueue.swift</c>), because the
/// behaviours users notice come out of it: <see cref="Tracks"/> is the base
/// order the caller supplied, <see cref="_order"/> is a permutation of indices
/// into it describing playback order, and <see cref="Position"/> indexes into
/// that permutation. Keeping the base order alongside the shuffled one is what
/// lets shuffle be turned back <em>off</em> and give the album back, and pinning
/// the current track at the front of a fresh shuffle is what stops toggling
/// shuffle from interrupting the song that is playing.
///
/// One deliberate divergence from the phone: its shuffle is a balanced spread
/// biased by device-local recency and taste scores, and this is a plain
/// Fisher-Yates. The desktop has no taste model to bias with yet; when it grows
/// one this is the single place that changes.
///
/// <see cref="Advance"/> and <see cref="AdvanceAfterFinish"/> are separate
/// because repeat-one distinguishes them: a track that plays to its end repeats,
/// but pressing next always moves on.
/// </summary>
public sealed class PlaybackQueue
{
    private readonly List<Track> _tracks = [];
    private readonly List<int> _order = [];

    public IReadOnlyList<Track> Tracks => _tracks;

    /// <summary>Index into the playback order, or -1 when the queue is empty.</summary>
    public int Position { get; private set; } = -1;

    public RepeatMode Repeat { get; set; } = RepeatMode.Off;

    public bool IsShuffled { get; private set; }

    public int Count => _tracks.Count;

    public bool IsEmpty => _tracks.Count == 0;

    public Track? Current =>
        Position >= 0 && Position < _order.Count ? _tracks[_order[Position]] : null;

    /// <summary>The tracks after the current one, in playback order.</summary>
    public IReadOnlyList<Track> UpNext =>
        Position < 0
            ? []
            : _order.Skip(Position + 1).Select(i => _tracks[i]).ToList();

    public bool HasNext =>
        !IsEmpty && (Repeat != RepeatMode.Off || Position + 1 < _order.Count);

    public bool HasPrevious =>
        !IsEmpty && (Repeat != RepeatMode.Off || Position > 0);

    /// <summary>
    /// What will play once the current track ends, without mutating — the engine
    /// preloads this to stitch it in gaplessly.
    /// </summary>
    public Track? PeekNext
    {
        get
        {
            if (IsEmpty) return null;
            switch (Repeat)
            {
                case RepeatMode.One:
                    return Current;
                case RepeatMode.Off:
                    var next = Position + 1;
                    return next < _order.Count ? _tracks[_order[next]] : null;
                default:
                    var wrapped = Position + 1;
                    return _tracks[_order[wrapped < _order.Count ? wrapped : 0]];
            }
        }
    }

    /// <summary>Replace the queue and begin at <paramref name="startIndex"/> (a base index).</summary>
    public void SetItems(IReadOnlyList<Track> tracks, int startIndex = 0)
    {
        _tracks.Clear();
        _tracks.AddRange(tracks);
        _order.Clear();

        if (_tracks.Count == 0)
        {
            Position = -1;
            return;
        }

        var start = Math.Clamp(startIndex, 0, _tracks.Count - 1);
        if (IsShuffled)
        {
            BuildShuffledOrder(pinning: start);
            Position = 0;
        }
        else
        {
            _order.AddRange(Enumerable.Range(0, _tracks.Count));
            Position = start;
        }
    }

    public void Clear()
    {
        _tracks.Clear();
        _order.Clear();
        Position = -1;
    }

    /// <summary>
    /// Turn shuffle on or off, keeping the current track playing. Turning it on
    /// reshuffles everything else behind the current track; turning it off
    /// restores the base order and lands on wherever the current track sits in it.
    /// </summary>
    public void SetShuffled(bool shuffled)
    {
        if (shuffled == IsShuffled) return;
        IsShuffled = shuffled;
        if (IsEmpty) return;

        var currentBase = Position >= 0 && Position < _order.Count ? _order[Position] : 0;
        _order.Clear();
        if (shuffled)
        {
            BuildShuffledOrder(pinning: currentBase);
            Position = 0;
        }
        else
        {
            _order.AddRange(Enumerable.Range(0, _tracks.Count));
            Position = currentBase;
        }
    }

    /// <summary>The user pressed next. Repeat-one is ignored — next always moves on.</summary>
    public bool Advance()
    {
        if (IsEmpty) return false;
        if (Position + 1 < _order.Count)
        {
            Position++;
            return true;
        }
        if (Repeat == RepeatMode.Off) return false;
        // Wrapping a shuffled queue reshuffles it, so a repeating shuffle does
        // not play the same permutation forever.
        if (IsShuffled) ReshuffleFromStart();
        Position = 0;
        return true;
    }

    /// <summary>A track played to its end. Repeat-one stays put.</summary>
    public bool AdvanceAfterFinish() => Repeat == RepeatMode.One || Advance();

    /// <summary>
    /// The user pressed previous. Restarting the current track when a few
    /// seconds in is the caller's policy, not the queue's, so this always steps
    /// to the genuinely previous track.
    /// </summary>
    public bool Retreat()
    {
        if (IsEmpty) return false;
        if (Position > 0)
        {
            Position--;
            return true;
        }
        if (Repeat == RepeatMode.Off) return false;
        Position = _order.Count - 1;
        return true;
    }

    /// <summary>Jump to a slot in the current playback order — what the queue panel clicks.</summary>
    public bool MoveToOrderIndex(int orderIndex)
    {
        if (orderIndex < 0 || orderIndex >= _order.Count) return false;
        Position = orderIndex;
        return true;
    }

    /// <summary>
    /// Park the queue on <paramref name="track"/>, used to reconcile with the
    /// engine after it has stitched in a preloaded track on its own.
    /// </summary>
    public bool MoveToTrack(Track track)
    {
        var baseIndex = _tracks.IndexOf(track);
        if (baseIndex < 0) return false;
        var orderIndex = _order.IndexOf(baseIndex);
        if (orderIndex < 0) return false;
        Position = orderIndex;
        return true;
    }

    /// <summary>The base index of a track, for callers that key off the supplied order.</summary>
    public int BaseIndexOf(Track track) => _tracks.IndexOf(track);

    private void BuildShuffledOrder(int pinning)
    {
        var rest = Enumerable.Range(0, _tracks.Count).Where(i => i != pinning).ToList();
        Shuffle(rest);
        _order.Add(pinning);
        _order.AddRange(rest);
    }

    private void ReshuffleFromStart()
    {
        var all = new List<int>(_order);
        Shuffle(all);
        _order.Clear();
        _order.AddRange(all);
    }

    private static void Shuffle(List<int> values)
    {
        for (var i = values.Count - 1; i > 0; i--)
        {
            var j = Random.Shared.Next(i + 1);
            (values[i], values[j]) = (values[j], values[i]);
        }
    }
}

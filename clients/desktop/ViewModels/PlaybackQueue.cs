using System.Collections.ObjectModel;
using Mozz.Desktop.Core;

namespace Mozz.Desktop.ViewModels;

public enum ShuffleMode
{
    Off,
    On,
}

public enum RepeatMode
{
    Off,
    All,
    One,
}

public sealed record QueueItemRow(int Number, Track Track, bool IsCurrent)
{
    public string NumberText => IsCurrent ? "Playing" : Number.ToString();
}

public sealed class PlaybackQueue
{
    private readonly List<Track> _tracks = [];
    private int _index = -1;

    public IReadOnlyList<Track> Tracks => _tracks;
    public int CurrentIndex => _index;
    public Track? Current => _index >= 0 && _index < _tracks.Count ? _tracks[_index] : null;
    public bool HasNext => NextIndex() is not null;
    public bool HasPrevious => PreviousIndex() is not null;
    public ShuffleMode Shuffle { get; private set; }
    public RepeatMode Repeat { get; private set; }

    public void Start(IReadOnlyList<Track> tracks, int index)
    {
        _tracks.Clear();
        _tracks.AddRange(tracks);
        _index = _tracks.Count == 0 ? -1 : Math.Clamp(index, 0, _tracks.Count - 1);
    }

    public int? NextIndex()
    {
        if (_tracks.Count == 0) return null;
        if (Repeat == RepeatMode.One) return _index;
        if (_index + 1 < _tracks.Count) return _index + 1;
        return Repeat == RepeatMode.All ? 0 : null;
    }

    public int? PreviousIndex()
    {
        if (_tracks.Count == 0) return null;
        if (_index > 0) return _index - 1;
        return Repeat == RepeatMode.All ? _tracks.Count - 1 : null;
    }

    public bool Remove(Track track)
    {
        var index = _tracks.IndexOf(track);
        if (index < 0) return false;
        _tracks.RemoveAt(index);
        if (_tracks.Count == 0) _index = -1;
        else if (index < _index) _index--;
        else if (index == _index) _index = Math.Min(_index, _tracks.Count - 1);
        return true;
    }

    public bool Move(Track track, int delta)
    {
        var from = _tracks.IndexOf(track);
        if (from < 0) return false;
        var to = from + delta;
        if (to < 0 || to >= _tracks.Count) return false;
        var item = _tracks[from];
        _tracks.RemoveAt(from);
        _tracks.Insert(to, item);
        if (_index == from) _index = to;
        else if (from < _index && to >= _index) _index--;
        else if (from > _index && to <= _index) _index++;
        return true;
    }

    public bool JumpTo(Track track, out int index)
    {
        index = _tracks.IndexOf(track);
        if (index < 0) return false;
        _index = index;
        return true;
    }

    public ShuffleMode ToggleShuffle()
    {
        Shuffle = Shuffle == ShuffleMode.Off ? ShuffleMode.On : ShuffleMode.Off;
        return Shuffle;
    }

    public void ShuffleUpcoming(Random? random = null)
    {
        if (_tracks.Count <= 2 || _index >= _tracks.Count - 1) return;
        random ??= Random.Shared;
        var tail = _tracks.Skip(_index + 1).OrderBy(_ => random.Next()).ToList();
        _tracks.RemoveRange(_index + 1, tail.Count);
        _tracks.AddRange(tail);
    }

    public RepeatMode CycleRepeat()
    {
        Repeat = Repeat switch
        {
            RepeatMode.Off => RepeatMode.All,
            RepeatMode.All => RepeatMode.One,
            _ => RepeatMode.Off,
        };
        return Repeat;
    }

    public IReadOnlyList<QueueItemRow> Rows() => _tracks
        .Select((track, i) => new QueueItemRow(i + 1, track, i == _index))
        .ToList();
}

public static class QueueProjection
{
    public static void ReplaceRows(ObservableCollection<QueueItemRow> target, PlaybackQueue queue)
    {
        target.Clear();
        foreach (var row in queue.Rows()) target.Add(row);
    }
}

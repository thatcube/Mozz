namespace Mozz.Desktop.Core;

public sealed record DesktopPlayEvent(
    string ServerId,
    string RemoteId,
    string Kind,
    double? PositionSeconds,
    double? DurationSeconds,
    DateTimeOffset CreatedAt);

public sealed class PlayHistoryRecorder(Action<DesktopPlayEvent> emit)
{
    private readonly object _gate = new();
    private Track? _pending;

    public Track? Pending
    {
        get
        {
            lock (_gate) return _pending;
        }
    }

    public void Start(Track track)
    {
        lock (_gate)
        {
            _pending = track;
            EmitLocked(track, "started", 0, track.DurationSeconds);
        }
    }

    public void CompleteCurrent(double? positionSeconds = null, double? durationSeconds = null) =>
        Terminal("completed", positionSeconds, durationSeconds);

    public void SkipCurrent(double? positionSeconds = null, double? durationSeconds = null) =>
        Terminal("skipped", positionSeconds, durationSeconds);

    public void SeekCurrent(double positionSeconds, double? durationSeconds = null)
    {
        lock (_gate)
        {
            if (_pending is not { } track) return;
            EmitLocked(track, "seek", Math.Max(0, positionSeconds), CleanDuration(durationSeconds ?? track.DurationSeconds));
        }
    }

    private void Terminal(string kind, double? positionSeconds, double? durationSeconds)
    {
        lock (_gate)
        {
            if (_pending is not { } track) return;
            _pending = null;
            EmitLocked(track, kind, positionSeconds, CleanDuration(durationSeconds ?? track.DurationSeconds));
        }
    }

    private void EmitLocked(Track track, string kind, double? positionSeconds, double? durationSeconds) =>
        emit(new DesktopPlayEvent(
            track.ServerId,
            track.RemoteId,
            kind,
            CleanPosition(positionSeconds),
            CleanDuration(durationSeconds),
            DateTimeOffset.UtcNow));

    private static double? CleanPosition(double? value) =>
        value is { } v && double.IsFinite(v) ? Math.Max(0, v) : null;

    private static double? CleanDuration(double? value) =>
        value is { } v && double.IsFinite(v) && v > 0 ? v : null;
}

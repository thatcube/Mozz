namespace Mozz.Desktop.Core;

public sealed record DesktopPlayEvent(
    string ServerId,
    string RemoteId,
    string Kind,
    double? PositionSeconds,
    double? DurationSeconds,
    DateTimeOffset CreatedAt);

public sealed record DesktopPlaybackReport(
    string ServerId,
    string RemoteId,
    string State,
    double PositionSeconds,
    DateTimeOffset CreatedAt);

public static class PlaybackReportSchedule
{
    public static readonly TimeSpan PeriodicInterval = TimeSpan.FromSeconds(20);

    public static bool ShouldReportProgress(
        bool isPlaying,
        double positionSeconds,
        DateTimeOffset now,
        DateTimeOffset? lastReportedAt,
        double? lastReportedPosition)
    {
        if (!isPlaying || !double.IsFinite(positionSeconds) || positionSeconds < 0) return false;
        if (lastReportedAt is null || lastReportedPosition is null) return true;
        if (now - lastReportedAt.Value < PeriodicInterval) return false;
        return positionSeconds - lastReportedPosition.Value >= 1;
    }
}

public sealed class PlayHistoryRecorder(
    Action<DesktopPlayEvent> emit,
    Action<DesktopPlaybackReport>? reportPlayback = null)
{
    private readonly object _gate = new();
    private Track? _pending;
    private DateTimeOffset? _lastPlaybackReportAt;
    private double? _lastPlaybackReportPosition;

    public Track? Pending
    {
        get
        {
            lock (_gate) return _pending;
        }
    }

    public void Start(Track track, DateTimeOffset? now = null)
    {
        lock (_gate)
        {
            _pending = track;
            EmitLocked(track, "started", 0, track.DurationSeconds);
            ReportLocked(track, "playing", 0, now);
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

    public void ProgressCurrent(double positionSeconds, DateTimeOffset? now = null)
    {
        lock (_gate)
        {
            if (_pending is not { } track) return;
            var at = now ?? DateTimeOffset.UtcNow;
            if (!PlaybackReportSchedule.ShouldReportProgress(
                    true,
                    positionSeconds,
                    at,
                    _lastPlaybackReportAt,
                    _lastPlaybackReportPosition))
            {
                return;
            }

            ReportLocked(track, "playing", positionSeconds, at);
        }
    }

    public void PauseCurrent(double? positionSeconds = null) => ReportState("paused", positionSeconds);

    public void ResumeCurrent(double? positionSeconds = null) => ReportState("playing", positionSeconds);

    private void Terminal(string kind, double? positionSeconds, double? durationSeconds)
    {
        lock (_gate)
        {
            if (_pending is not { } track) return;
            _pending = null;
            EmitLocked(track, kind, positionSeconds, CleanDuration(durationSeconds ?? track.DurationSeconds));
            ReportLocked(track, "stopped", positionSeconds ?? durationSeconds ?? track.DurationSeconds);
            _lastPlaybackReportAt = null;
            _lastPlaybackReportPosition = null;
        }
    }

    private void ReportState(string state, double? positionSeconds)
    {
        lock (_gate)
        {
            if (_pending is not { } track) return;
            ReportLocked(track, state, positionSeconds);
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

    private void ReportLocked(Track track, string state, double? positionSeconds, DateTimeOffset? now = null)
    {
        if (reportPlayback is null) return;
        var at = now ?? DateTimeOffset.UtcNow;
        var clean = CleanPosition(positionSeconds) ?? 0;
        _lastPlaybackReportAt = at;
        _lastPlaybackReportPosition = clean;
        reportPlayback(new DesktopPlaybackReport(track.ServerId, track.RemoteId, state, clean, at));
    }
}

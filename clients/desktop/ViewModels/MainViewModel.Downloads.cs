using System.Collections.ObjectModel;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Mozz.Desktop.Core;
using Mozz.Desktop.Core.Downloads;

namespace Mozz.Desktop.ViewModels;

/// <summary>
/// The Downloads pane: driving the core's download lifecycle and showing what it
/// holds. The heavy lifting — enqueue, resolve, fetch the bytes, report progress,
/// complete or fail — lives in <see cref="DownloadService"/>; this partial is the
/// thin band between that service and the view. Progress is polled, not pushed
/// (the core stores counters, so a timer reads them), which is why a
/// <see cref="DispatcherTimer"/> and not a subscription refreshes the list.
/// </summary>
public sealed partial class MainViewModel
{
    private DownloadService? _downloads;
    private DispatcherTimer? _downloadPollTimer;

    // Tracks that are actively transferring, so Cancel can stop one mid-flight
    // (the token) rather than only failing a queued record through the core.
    private readonly Dictionary<(string ServerId, string RemoteId), CancellationTokenSource> _downloadCts = new();

    // The core's records carry ids, not titles. We remember the title of anything
    // we enqueue so the pane reads as track names; a record from a previous run,
    // whose title we never saw, falls back to its remote id rather than nothing.
    private readonly Dictionary<(string ServerId, string RemoteId), string> _downloadTitles = new();

    private int _activeDownloadCount;

    /// <summary>Rows the Downloads pane's list binds to, newest transfer first.</summary>
    public ObservableCollection<DownloadRow> DownloadRows { get; } = new();

    [ObservableProperty] private string _downloadStorageSummary = "No downloads yet.";

    public bool IsDownloadsSelected => Section == LibrarySection.Downloads;

    public bool ShowDownloads =>
        _navigation.Current is { Kind: LibraryPageKind.Section, Section: LibrarySection.Downloads };

    private void InitializeDownloads()
    {
        // Construction touches nothing, so it is safe in the designer; only the
        // polling timer (which would tick against a live core) is held back.
        _downloads = new DownloadService(
            new DownloadCommands(_core), _server, new HttpByteStreamFactory());

        if (Avalonia.Controls.Design.IsDesignMode) return;

        _downloadPollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
        _downloadPollTimer.Tick += (_, _) =>
        {
            // Only spend a round trip when someone is watching the pane or a
            // transfer is in flight and its progress bar needs to move.
            if (Section == LibrarySection.Downloads || _activeDownloadCount > 0)
                _ = RefreshDownloadsAsync();
        };
        _downloadPollTimer.Start();
    }

    [RelayCommand]
    private async Task RefreshDownloads() => await RefreshDownloadsAsync();

    private async Task RefreshDownloadsAsync()
    {
        if (_downloads is null) return;
        try
        {
            var items = await _downloads.ListAsync();
            var usage = await _downloads.StorageUsageAsync();

            // Running transfers to the top, then most-recently requested, so the
            // thing the user just acted on is where they are looking.
            var rows = items
                .OrderByDescending(i => i.State == DownloadPhase.Downloading)
                .ThenByDescending(i => i.RequestedAt)
                .Select(i => DownloadRow.From(
                    i,
                    _downloadTitles.TryGetValue((i.ServerId, i.RemoteId), out var title)
                        ? title
                        : i.RemoteId))
                .ToList();

            var summary = usage.DownloadedTrackCount == 0
                ? "No downloads yet."
                : $"{usage.DownloadedTrackCount} " +
                  $"{(usage.DownloadedTrackCount == 1 ? "track" : "tracks")} · " +
                  DownloadFormatting.Bytes(usage.TotalBytes);

            Dispatcher.UIThread.Post(() =>
            {
                Replace(DownloadRows, rows);
                DownloadStorageSummary = summary;
            });
        }
        catch (Exception ex)
        {
            Dispatcher.UIThread.Post(() => StatusMessage = $"Couldn't read downloads: {ex.Message}");
        }
    }

    [RelayCommand]
    private async Task DownloadTrack(Track? track)
    {
        if (track is null) return;
        await StartDownloadAsync(track);
        await RefreshDownloadsAsync();
    }

    [RelayCommand]
    private async Task DownloadAlbum()
    {
        // Snapshot the detail page's tracks: the download runs long enough that
        // the user could navigate away and mutate the live list underneath us.
        var tracks = _detailAlbumTracks.Select(r => r.Track).ToList();
        if (tracks.Count == 0) return;

        StatusMessage = tracks.Count == 1
            ? $"Downloading {tracks[0].Title}…"
            : $"Downloading {tracks.Count} tracks…";

        foreach (var track in tracks)
            await StartDownloadAsync(track);

        await RefreshDownloadsAsync();
    }

    private async Task StartDownloadAsync(Track track)
    {
        if (_downloads is null) return;

        var key = (track.ServerId, track.RemoteId);
        _downloadTitles[key] = track.Title;

        // Already transferring — don't start a second pull of the same bytes.
        if (_downloadCts.ContainsKey(key)) return;

        var cts = new CancellationTokenSource();
        _downloadCts[key] = cts;
        _activeDownloadCount++;
        try
        {
            var item = await _downloads.DownloadAsync(track.ServerId, track.RemoteId, cts.Token);
            StatusMessage = item.State switch
            {
                DownloadPhase.Downloaded => $"Downloaded {track.Title}",
                DownloadPhase.Failed when item.WasCancelled => $"Cancelled {track.Title}",
                DownloadPhase.Failed => $"Download failed: {item.ErrorMessage}",
                _ => StatusMessage,
            };
        }
        finally
        {
            _activeDownloadCount--;
            _downloadCts.Remove(key);
            cts.Dispose();
        }
    }

    [RelayCommand]
    private async Task CancelDownload(DownloadRow? row)
    {
        if (row is null || _downloads is null) return;
        var key = (row.ServerId, row.RemoteId);

        // A live transfer stops through its token; a record that is only queued
        // (e.g. left over from a previous run, with no token here) is cancelled
        // through the core, which marks it Failed("Cancelled").
        if (_downloadCts.TryGetValue(key, out var cts))
        {
            cts.Cancel();
        }
        else
        {
            try
            {
                await _downloads.CancelAsync(row.ServerId, row.RemoteId);
            }
            catch (Exception ex)
            {
                StatusMessage = $"Couldn't cancel: {ex.Message}";
            }
        }

        await RefreshDownloadsAsync();
    }

    [RelayCommand]
    private async Task DeleteDownload(DownloadRow? row)
    {
        if (row is null || _downloads is null) return;
        var key = (row.ServerId, row.RemoteId);

        // Stop it first if it is still running, so we don't delete a record the
        // transfer is about to complete back into existence.
        if (_downloadCts.TryGetValue(key, out var cts))
            cts.Cancel();

        try
        {
            await _downloads.DeleteAsync(row.ServerId, row.RemoteId);
            _downloadTitles.Remove(key);
            StatusMessage = $"Removed {row.Title}";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't delete: {ex.Message}";
        }

        await RefreshDownloadsAsync();
    }
}

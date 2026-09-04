using Mozz.Desktop.Core.Downloads;

namespace Mozz.Desktop.ViewModels;

/// <summary>
/// Turns a <see cref="DownloadItem"/> — ids, byte counts and a state — into the
/// handful of strings and flags a row in the Downloads pane binds to. Kept out of
/// the view model and free of any framework type so the formatting is unit
/// tested directly, the way the other *Presentation helpers in this folder are.
/// </summary>
public static class DownloadFormatting
{
    private static readonly string[] Units = ["B", "KB", "MB", "GB", "TB"];

    /// <summary>A human byte size: "0 B", "512 B", "1.4 MB". Binary units, one
    /// decimal once past bytes, which is what a downloads list wants to read.</summary>
    public static string Bytes(long value)
    {
        if (value < 0) value = 0;
        double size = value;
        var unit = 0;
        while (size >= 1024 && unit < Units.Length - 1)
        {
            size /= 1024;
            unit++;
        }

        return unit == 0
            ? $"{value} {Units[unit]}"
            : $"{size:0.#} {Units[unit]}";
    }

    /// <summary>
    /// The single line that describes where a download stands: its size when done,
    /// a percentage or transferred amount while running, "Queued" before it starts,
    /// "Cancelled" for a cancelled one, and the reason for a genuine failure.
    /// </summary>
    public static string Detail(DownloadItem item) => item.State switch
    {
        DownloadPhase.Downloaded => Bytes(item.TotalBytes ?? item.ReceivedBytes),
        DownloadPhase.Downloading when item.Fraction is { } fraction =>
            $"Downloading… {fraction * 100:0}%",
        DownloadPhase.Downloading => $"Downloading… {Bytes(item.ReceivedBytes)}",
        DownloadPhase.Queued => "Queued",
        DownloadPhase.Failed when item.WasCancelled => "Cancelled",
        DownloadPhase.Failed => $"Failed: {item.ErrorMessage ?? "unknown error"}",
        _ => "Not downloaded",
    };

    public static string StateLabel(DownloadItem item) => item.State switch
    {
        DownloadPhase.Downloaded => "Downloaded",
        DownloadPhase.Downloading => "Downloading",
        DownloadPhase.Queued => "Queued",
        DownloadPhase.Failed when item.WasCancelled => "Cancelled",
        DownloadPhase.Failed => "Failed",
        _ => "Not downloaded",
    };
}

/// <summary>
/// One row in the Downloads pane. A flat, get-only projection so the compiled
/// bindings (<c>x:DataType</c>) resolve every path at build time.
/// </summary>
public sealed class DownloadRow
{
    private DownloadRow(DownloadItem item, string title)
    {
        ServerId = item.ServerId;
        RemoteId = item.RemoteId;
        Title = title;
        StateLabel = DownloadFormatting.StateLabel(item);
        Detail = DownloadFormatting.Detail(item);
        // A determinate bar only while downloading with a known total; otherwise
        // there is nothing honest to show, so the bar stays hidden.
        ShowProgress = item.State == DownloadPhase.Downloading && item.Fraction is not null;
        ProgressFraction = item.Fraction ?? 0;
        IsDownloaded = item.State == DownloadPhase.Downloaded;
        IsFailed = item.State == DownloadPhase.Failed;
    }

    public string ServerId { get; }
    public string RemoteId { get; }
    public string Title { get; }
    public string StateLabel { get; }
    public string Detail { get; }
    public bool ShowProgress { get; }
    public double ProgressFraction { get; }
    public bool IsDownloaded { get; }
    public bool IsFailed { get; }

    public static DownloadRow From(DownloadItem item, string title) => new(item, title);
}

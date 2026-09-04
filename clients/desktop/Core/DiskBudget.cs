namespace Mozz.Desktop.Core;

/// <summary>
/// Keeps a directory of cached files under a byte budget by deleting the
/// least recently used.
///
/// The desktop artwork cache wrote covers to disk and never removed one, except
/// the single case of a file that failed to decode. It had no budget and no
/// eviction at all, so it grew for as long as the app was used: 35 MB across
/// 1,211 files after browsing a fraction of a 5,973 album library. iOS has had
/// a bounded cache with LRU eviction since the beginning. Two implementations
/// of one idea, and only one of them finished - which is the ordinary cost of
/// solving the same problem twice, and the reason artwork bytes belong in the
/// core rather than in each shell.
///
/// Recency comes from the file's modification time rather than an index. An
/// index would be exact, but it turns every cache read into a write, and this
/// runs while scrolling a wall of covers. The approximation is the same one
/// iOS makes, deliberately, so the two behave alike until they are one.
/// </summary>
public sealed class DiskBudget
{
    private readonly string _directory;
    private readonly string _extension;
    private readonly long _byteLimit;

    public DiskBudget(string directory, long byteLimit, string extension = ".img")
    {
        _directory = directory;
        _byteLimit = byteLimit;
        _extension = extension;
    }

    /// <summary>
    /// Delete oldest-first until the directory fits the budget. Returns the
    /// number of bytes removed, which is zero when nothing needed removing.
    /// </summary>
    public long Enforce()
    {
        List<FileInfo> files;
        try
        {
            var dir = new DirectoryInfo(_directory);
            if (!dir.Exists) return 0;
            files = dir.EnumerateFiles("*" + _extension).ToList();
        }
        catch
        {
            // A directory we cannot read is not a directory we should prune.
            return 0;
        }

        long total = 0;
        foreach (var file in files)
        {
            try { total += file.Length; }
            catch { /* vanished between listing and stat; it is not taking space */ }
        }

        if (total <= _byteLimit) return 0;

        long removed = 0;
        foreach (var file in files.OrderBy(f => SafeWriteTime(f)))
        {
            if (total - removed <= _byteLimit) break;
            long size;
            try { size = file.Length; } catch { continue; }
            try { file.Delete(); }
            catch { continue; }   // locked or already gone; it will be considered again next time
            removed += size;
        }

        return removed;
    }

    private static DateTime SafeWriteTime(FileInfo file)
    {
        // A file whose timestamp cannot be read sorts oldest, so a directory of
        // unreadable entries still drains rather than pinning the cache above
        // its budget forever.
        try { return file.LastWriteTimeUtc; }
        catch { return DateTime.MinValue; }
    }
}

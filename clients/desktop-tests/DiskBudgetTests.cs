using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The desktop artwork cache wrote covers to disk and never removed one,
/// except the single case of a file that failed to decode. No budget, no
/// eviction: 35 MB across 1,211 files after browsing a fraction of a 5,973
/// album library, and growing for as long as the app was used. iOS has had a
/// bounded LRU cache from the start. These tests pin the desktop side to the
/// same promise.
/// </summary>
public class DiskBudgetTests : IDisposable
{
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "mozz-diskbudget-" + Guid.NewGuid().ToString("N"));

    public DiskBudgetTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    private string Write(string name, int bytes, DateTime written)
    {
        var path = Path.Combine(_dir, name + ".img");
        File.WriteAllBytes(path, new byte[bytes]);
        File.SetLastWriteTimeUtc(path, written);
        return path;
    }

    [Fact]
    public void ADirectoryInsideItsBudgetIsLeftAlone()
    {
        Write("a", 100, DateTime.UtcNow);
        Write("b", 100, DateTime.UtcNow);

        Assert.Equal(0, new DiskBudget(_dir, byteLimit: 1000).Enforce());
        Assert.Equal(2, Directory.GetFiles(_dir).Length);
    }

    [Fact]
    public void TheLeastRecentlyUsedGoFirst()
    {
        var old = Write("old", 100, DateTime.UtcNow.AddDays(-9));
        var mid = Write("mid", 100, DateTime.UtcNow.AddDays(-4));
        var fresh = Write("fresh", 100, DateTime.UtcNow);

        new DiskBudget(_dir, byteLimit: 250).Enforce();

        Assert.False(File.Exists(old), "the oldest cover should have gone first");
        Assert.True(File.Exists(mid));
        Assert.True(File.Exists(fresh));
    }

    [Fact]
    public void ItStopsAsSoonAsTheBudgetIsMetRatherThanEmptyingTheCache()
    {
        for (var i = 0; i < 10; i++) Write($"f{i}", 100, DateTime.UtcNow.AddMinutes(-i));

        new DiskBudget(_dir, byteLimit: 500).Enforce();

        // Five of ten fit the budget; deleting more would throw away covers that
        // cost a network round trip each to replace.
        Assert.Equal(5, Directory.GetFiles(_dir).Length);
    }

    /// <summary>
    /// Only the cache's own files are its to delete. A budget that swept the
    /// whole directory would take anything a neighbouring feature had put there.
    /// </summary>
    [Fact]
    public void FilesWithAnotherExtensionAreNotTouched()
    {
        Write("cover", 1000, DateTime.UtcNow.AddDays(-9));
        var foreign = Path.Combine(_dir, "notes.txt");
        File.WriteAllBytes(foreign, new byte[1000]);

        new DiskBudget(_dir, byteLimit: 10).Enforce();

        Assert.True(File.Exists(foreign), "a file the cache did not write is not its to delete");
    }

    [Fact]
    public void AMissingDirectoryIsNotAnError()
    {
        var absent = Path.Combine(_dir, "does-not-exist");
        Assert.Equal(0, new DiskBudget(absent, byteLimit: 10).Enforce());
    }

    /// <summary>
    /// Enforcing twice must not delete twice as much: the second call sees a
    /// directory already inside its budget and should do nothing.
    /// </summary>
    [Fact]
    public void EnforcingAgainAfterPruningIsANoOp()
    {
        for (var i = 0; i < 6; i++) Write($"f{i}", 100, DateTime.UtcNow.AddMinutes(-i));

        var budget = new DiskBudget(_dir, byteLimit: 300);
        Assert.True(budget.Enforce() > 0);
        Assert.Equal(0, budget.Enforce());
        Assert.Equal(3, Directory.GetFiles(_dir).Length);
    }
}

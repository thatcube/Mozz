using Mozz.Desktop.Core;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Reproduces the recycled-tile hazard without a window: a load started for one
/// key is made to complete after the tile has been rebound to another, and the
/// binder must discard the stale result rather than paint it. <c>post</c> is left
/// at its inline default so completion is deterministic and single-threaded.
/// </summary>
public class ArtworkBinderTests
{
    private static ArtworkRef Ref(string key) => new("srv", key, 100);

    [Fact]
    public void NullRequest_ShowsFallback_WithoutLoading()
    {
        var loads = 0;
        var applied = new List<string?>();
        using var binder = new ArtworkBinder<string>(
            load: (r, ct) => { loads++; return Task.FromResult<string?>("cover"); },
            apply: v => applied.Add(v));

        binder.Bind(null);

        Assert.Equal(0, loads);
        Assert.Equal(new string?[] { null }, applied);
    }

    [Fact]
    public void RepeatBindToSameKey_DoesNotReload()
    {
        var loads = 0;
        var applied = new List<string?>();
        using var binder = new ArtworkBinder<string>(
            load: (r, ct) => { loads++; return Task.FromResult<string?>("cover-" + r.ArtworkKey); },
            apply: v => applied.Add(v));

        binder.Bind(Ref("a"));
        binder.Bind(Ref("a")); // identical request: the good load must not restart

        Assert.Equal(1, loads);
        Assert.Equal(new string?[] { null, "cover-a" }, applied);
    }

    [Fact]
    public async Task StaleLoad_IsDiscardedAfterRebind()
    {
        var applied = new List<string?>();
        var gates = new Dictionary<string, TaskCompletionSource<string?>>();
        using var binder = new ArtworkBinder<string>(
            load: (r, ct) =>
            {
                var tcs = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                gates[r.ArtworkKey] = tcs;
                return tcs.Task;
            },
            apply: v => applied.Add(v));

        binder.Bind(Ref("A")); // load for A is now pending
        binder.Bind(Ref("B")); // tile recycled to B; A's load is superseded

        // A finishes late — its container is B now, so this result is stale.
        gates["A"].SetResult("cover-A");
        await Task.Delay(20);
        Assert.DoesNotContain("cover-A", applied);

        // B finishes and is current, so it applies.
        gates["B"].SetResult("cover-B");
        await Task.Delay(20);
        Assert.Equal("cover-B", applied[^1]);
    }

    [Fact]
    public void RebindAToBToA_ShowsA_NotTheFirstAsLoad()
    {
        var applied = new List<string?>();
        using var binder = new ArtworkBinder<string>(
            load: (r, ct) => Task.FromResult<string?>("cover-" + r.ArtworkKey),
            apply: v => applied.Add(v));

        binder.Bind(Ref("A"));
        binder.Bind(Ref("B"));
        binder.Bind(Ref("A")); // back to A: a newer generation, must reload and win

        Assert.Equal("cover-A", applied[^1]);
    }
}

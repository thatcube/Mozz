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
    /// <summary>
    /// Polls until <paramref name="condition"/> holds, or the deadline passes.
    /// Waiting on the condition rather than on a fixed delay is what keeps these
    /// tests honest on a machine that is busy.
    /// </summary>
    private static async Task<bool> WaitUntil(Func<bool> condition, int timeoutMs = 10_000)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (!condition() && clock.ElapsedMilliseconds < timeoutMs)
            await Task.Delay(5);
        return condition();
    }

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

    /// <summary>
    /// A stand-in shows instead of the fallback, and still yields to the real one.
    ///
    /// The clear-to-fallback is what stops a recycled tile from showing the
    /// previous item's cover, and it ran unconditionally — so a caller that
    /// already held this very picture at another size had it wiped a frame after
    /// handing it over, and the page drew a placeholder for artwork the app had.
    /// </summary>
    [Fact]
    public async Task StandIn_ShowsWhileLoading_ThenGivesWayToTheRealCover()
    {
        var gate = new TaskCompletionSource<string?>();
        var applied = new List<string?>();
        using var binder = new ArtworkBinder<string>(
            load: (r, ct) => gate.Task,
            apply: v => applied.Add(v));

        binder.Bind(Ref("a"), standIn: "smaller-copy");
        Assert.Equal(new string?[] { "smaller-copy" }, applied);

        gate.SetResult("cover-a");
        Assert.True(await WaitUntil(() => applied.Count == 2));
        Assert.Equal("cover-a", applied[^1]);
    }

    /// <summary>
    /// With no stand-in offered, the tile still clears — the recycling guard is
    /// the default, not the exception.
    /// </summary>
    [Fact]
    public void NoStandIn_StillClearsToFallback()
    {
        var applied = new List<string?>();
        using var binder = new ArtworkBinder<string>(
            load: (r, ct) => new TaskCompletionSource<string?>().Task,
            apply: v => applied.Add(v));

        binder.Bind(Ref("a"));

        Assert.Equal(new string?[] { null }, applied);
    }

    /// <summary>A stand-in belongs to its generation: a rebind past it discards it.</summary>
    [Fact]
    public void StandInFromASupersededBind_IsNotPainted()
    {
        var applied = new List<string?>();
        var posts = new List<Action>();
        using var binder = new ArtworkBinder<string>(
            load: (r, ct) => new TaskCompletionSource<string?>().Task,
            apply: v => applied.Add(v),
            post: posts.Add);

        binder.Bind(Ref("a"), standIn: "a-smaller");
        binder.Bind(Ref("b"), standIn: "b-smaller");

        foreach (var post in posts) post();

        // "a-smaller" was queued before the rebind to b and must not land on b.
        Assert.Equal(new string?[] { "b-smaller" }, applied);
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

        // These loads complete on the thread pool (RunContinuationsAsynchronously),
        // so the test has to wait for a condition rather than sleep a guessed
        // number of milliseconds — a fixed delay passed here and failed on a
        // loaded Windows runner, where 20ms elapsed before the continuation ran
        // and the list still held only the clearing null.
        //
        // A is completed first and B second, and the wait below does not return
        // until B has been applied. A's continuation was queued ahead of B's, so
        // by then it has had its turn: if it were going to paint, it would have.
        gates["A"].SetResult("cover-A");
        gates["B"].SetResult("cover-B");

        Assert.True(await WaitUntil(() => applied.Contains("cover-B")),
            "the current request's cover should have been applied");
        Assert.DoesNotContain("cover-A", applied);
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

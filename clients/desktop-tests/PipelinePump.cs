using System.Diagnostics;
using Mozz.Desktop.Audio;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Drains a <see cref="PcmPipeline"/> the way a sound card would, for tests that
/// need to wait on <c>PlaybackEnded</c> or <c>Error</c>.
/// </summary>
/// <remarks>
/// The obvious spin loop — <c>while (!ended.IsSet &amp;&amp; guard++ &lt; 100_000) Render(buf);</c>
/// — is wrong in two ways, and both of them only show up on a loaded machine:
///
/// <list type="number">
/// <item><description>
/// <b>The reader raises the events.</b> <c>PlaybackEnded</c> is enqueued from
/// <c>Render</c>, because it is the reader that discovers the ring has run dry at
/// the end frame. Waiting on the event without rendering therefore waits forever.
/// </description></item>
/// <item><description>
/// <b>An iteration count is not a timeout.</b> When the pump thread is starved the
/// ring stays empty, <c>Render</c> consumes nothing, and 100,000 iterations burn
/// through in milliseconds without ever reaching the end frame. The guard then
/// exits the loop, after which nothing renders at all and the event can never
/// arrive. On an idle machine the pump keeps up and the same test passes.
/// </description></item>
/// </list>
///
/// So bound by <i>time</i>, keep rendering for the whole wait, and yield between
/// bursts so the pump thread can actually refill the ring. Yielding also makes the
/// reader strictly slower than a pure spin, which can only reduce the underrun
/// these tests take pains to avoid.
/// </remarks>
internal static class PipelinePump
{
    private static readonly TimeSpan DefaultLimit = TimeSpan.FromSeconds(10);

    /// <summary>Render until <paramref name="signal"/> fires, or the deadline passes.</summary>
    /// <param name="onRendered">Optional hook to capture each rendered buffer.</param>
    /// <returns>Whether the signal fired.</returns>
    public static bool RenderUntil(
        PcmPipeline pipe,
        float[] buffer,
        ManualResetEventSlim signal,
        Action<float[]>? onRendered = null,
        TimeSpan? timeout = null)
    {
        var limit = timeout ?? DefaultLimit;
        var clock = Stopwatch.StartNew();

        while (!signal.IsSet && clock.Elapsed < limit)
        {
            for (int i = 0; i < 16 && !signal.IsSet; i++)
            {
                pipe.Render(buffer);
                onRendered?.Invoke(buffer);
            }
            Thread.Sleep(1); // let the pump thread refill the ring
        }

        return signal.IsSet;
    }

    /// <summary>
    /// As <see cref="RenderUntil"/>, but fails the test with <paramref name="because"/>
    /// if the signal never arrives.
    /// </summary>
    public static void RenderUntilOrFail(
        PcmPipeline pipe,
        float[] buffer,
        ManualResetEventSlim signal,
        string because,
        Action<float[]>? onRendered = null,
        TimeSpan? timeout = null)
        => Assert.True(RenderUntil(pipe, buffer, signal, onRendered, timeout), because);
}

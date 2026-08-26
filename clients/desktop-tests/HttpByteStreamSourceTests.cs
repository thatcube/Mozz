using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using Mozz.Desktop.Audio.Streaming;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The HTTP byte source is the one part of the new audio path that has real
/// logic of its own — everything else forwards to Rust. Its rules are the ones
/// a listener would notice go wrong: a server that honours ranges is read in
/// order, a server that ignores them is trusted only at offset zero (anywhere
/// else it would decode the start of the file while claiming to be elsewhere,
/// which sounds like corruption), and running off the end is a clean stop, not
/// an error. These run against a stub handler, so no socket and no dylib.
/// </summary>
public class HttpByteStreamSourceTests
{
    private enum Mode
    {
        /// <summary>Answers 206 with a correct Content-Range total.</summary>
        HonoursRange,
        /// <summary>Ignores Range and answers 200 with the whole body every time.</summary>
        IgnoresRange,
        /// <summary>Answers 206 but never reveals the total, then 416 past the end.</summary>
        NoLengthThen416,
    }

    private sealed class StubHandler(Mode mode, byte[] payload) : HttpMessageHandler
    {
        public int Requests { get; private set; }

        protected override HttpResponseMessage Send(HttpRequestMessage request, CancellationToken ct)
        {
            Requests++;
            (long start, long end) = ParseRange(request);

            if (mode == Mode.IgnoresRange)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new ByteArrayContent(payload),
                };
            }

            if (start >= payload.Length)
            {
                return new HttpResponseMessage(HttpStatusCode.RequestedRangeNotSatisfiable)
                {
                    Content = new ByteArrayContent(Array.Empty<byte>()),
                };
            }

            long last = Math.Min(end, payload.Length - 1);
            int len = (int)(last - start + 1);
            var slice = new byte[len];
            Array.Copy(payload, start, slice, 0, len);

            var response = new HttpResponseMessage(HttpStatusCode.PartialContent)
            {
                Content = new ByteArrayContent(slice),
            };
            if (mode == Mode.HonoursRange)
            {
                response.Content.Headers.ContentRange =
                    new ContentRangeHeaderValue(start, last, payload.Length);
            }
            return response;
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            => Task.FromResult(Send(request, ct));

        private static (long, long) ParseRange(HttpRequestMessage request)
        {
            if (!request.Headers.TryGetValues("Range", out var values))
                return (0, long.MaxValue);
            string raw = values.First().Replace("bytes=", "");
            string[] parts = raw.Split('-');
            long start = long.Parse(parts[0]);
            long end = parts.Length > 1 && parts[1].Length > 0 ? long.Parse(parts[1]) : long.MaxValue;
            return (start, end);
        }
    }

    private static byte[] Pattern(int n)
    {
        var b = new byte[n];
        for (int i = 0; i < n; i++) b[i] = (byte)(i * 7 + 3);
        return b;
    }

    private static byte[] ReadAll(ByteStreamSource source, int chunk = 7)
    {
        using var acc = new MemoryStream();
        var buf = new byte[chunk];
        while (true)
        {
            int n = source.Read(buf);
            Assert.True(n >= 0, "read reported an error");
            if (n == 0) break;
            acc.Write(buf, 0, n);
        }
        return acc.ToArray();
    }

    [Fact]
    public void HonoursRange_ReadsTheWholeStreamInOrder()
    {
        var payload = Pattern(40);
        using var http = new HttpClient(new StubHandler(Mode.HonoursRange, payload));
        using var src = new HttpByteStreamSource("http://server/track", client: http, chunkSize: 8);

        Assert.Equal(payload, ReadAll(src));
    }

    [Fact]
    public void IgnoresRange_IsTrustedAtOffsetZero()
    {
        // A server that returns 200 with the whole body is honest at the start.
        var payload = Pattern(40);
        using var http = new HttpClient(new StubHandler(Mode.IgnoresRange, payload));
        using var src = new HttpByteStreamSource("http://server/track", client: http, chunkSize: 8);

        Assert.Equal(payload, ReadAll(src));
    }

    [Fact]
    public void IgnoresRange_IsRejectedAfterASeek_RatherThanDecodingFromZero()
    {
        // This is the whole reason the class exists: a 200 answering a ranged
        // request from a non-zero offset must fail, not silently hand back the
        // start of the file as if it were the middle.
        var payload = Pattern(40);
        using var http = new HttpClient(new StubHandler(Mode.IgnoresRange, payload));
        using var src = new HttpByteStreamSource("http://server/track", client: http, chunkSize: 8);

        Assert.Equal(20, src.Seek(20, 0)); // whence 0 = from start
        int n = src.Read(new byte[8]);

        Assert.Equal(-1, n);
    }

    [Fact]
    public void RunningOffTheEnd_IsACleanStop_EvenWhenTheLengthWasNeverAnnounced()
    {
        // 206 without a Content-Range never reveals the total, so the stream
        // only ends when a fetch past the end returns 416. That must read as
        // end-of-stream (0), not as a failure (-1).
        var payload = Pattern(40);
        using var http = new HttpClient(new StubHandler(Mode.NoLengthThen416, payload));
        using var src = new HttpByteStreamSource("http://server/track", client: http, chunkSize: 8);

        Assert.Equal(payload, ReadAll(src));
    }

    [Fact]
    public void Seek_FromTheEnd_ResolvesAgainstTheDiscoveredTotal()
    {
        var payload = Pattern(40);
        using var http = new HttpClient(new StubHandler(Mode.HonoursRange, payload));
        using var src = new HttpByteStreamSource("http://server/track", client: http, chunkSize: 8);

        // whence 2 = from end; -10 lands ten bytes before the end.
        Assert.Equal(30, src.Seek(-10, 2));
        var tail = ReadAll(src);
        Assert.Equal(payload[30..], tail);
    }
}

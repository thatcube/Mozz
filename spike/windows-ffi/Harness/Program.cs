using System.Runtime.InteropServices;
using System.Text.Json;

// Mozz Windows FFI spike — C# host harness.
//
// Loads the Swift-built MozzFFI shared library and drives the platform-free
// core through its C ABI. See ../README.md for what this is proving and why.
//
// Exit code is 0 only if every gate passes, so CI goes red on a real failure
// rather than printing a sad number and moving on.

internal static class Native
{
    // SwiftPM emits MozzFFI.dll on Windows, libMozzFFI.dylib on macOS and
    // libMozzFFI.so on Linux. .NET's probing handles the prefix/extension, so
    // the bare name works on all three and this harness stays portable.
    private const string Library = "MozzFFI";

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr mozz_ffi_probe();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr mozz_ffi_benchmark(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string dbPath, int trackCount);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr mozz_ffi_search(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string dbPath,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string query,
        int limit);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void mozz_ffi_free_string(IntPtr pointer);

    /// Marshal a returned C string and hand the buffer straight back to Swift.
    /// Every pointer the core returns is caller-owned and freed exactly once.
    private static JsonElement Consume(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero)
        {
            throw new InvalidOperationException("core returned a null pointer");
        }

        try
        {
            var json = Marshal.PtrToStringUTF8(pointer)
                ?? throw new InvalidOperationException("could not marshal returned string");
            using var document = JsonDocument.Parse(json);
            return document.RootElement.Clone();
        }
        finally
        {
            mozz_ffi_free_string(pointer);
        }
    }

    private static JsonElement Unwrap(JsonElement envelope, string call)
    {
        if (!envelope.GetProperty("ok").GetBoolean())
        {
            var error = envelope.TryGetProperty("error", out var e) ? e.GetString() : "unknown";
            throw new InvalidOperationException($"{call} failed: {error}");
        }

        return envelope.GetProperty("payload");
    }

    public static JsonElement Probe() => Unwrap(Consume(mozz_ffi_probe()), "probe");

    public static JsonElement Benchmark(string dbPath, int trackCount) =>
        Unwrap(Consume(mozz_ffi_benchmark(dbPath, trackCount)), "benchmark");

    public static JsonElement Search(string dbPath, string query, int limit) =>
        Unwrap(Consume(mozz_ffi_search(dbPath, query, limit)), "search");
}

internal static class Program
{
    // The published iOS numbers this spike is measured against (iPhone 17 Pro
    // Max, 100k tracks). Not pass/fail on their own — different hardware — but
    // an order-of-magnitude regression means the boundary design is wrong.
    private const double IosSearchP95Ms = 15.7;
    private const double IosColdOpenMs = 66.4;
    private const double IosPageFetchMs = 3.8;

    // The hard product requirement, independent of platform.
    private const double SearchP95BudgetMs = 100.0;

    private static int Main(string[] args)
    {
        var trackCount = args.Length > 0 && int.TryParse(args[0], out var parsed) ? parsed : 100_000;
        var failures = new List<string>();

        try
        {
            Console.WriteLine("=== 1. Probe: does the core load, and does SQLite have FTS5? ===");
            var probe = Native.Probe();
            var platform = probe.GetProperty("platform").GetString();
            var sqlite = probe.GetProperty("sqliteVersion").GetString();
            var hasFts5 = probe.GetProperty("hasFTS5").GetBoolean();
            var fts5Created = probe.GetProperty("fts5CreateSucceeded").GetBoolean();

            Console.WriteLine($"  platform        : {platform}");
            Console.WriteLine($"  SQLite          : {sqlite}");
            Console.WriteLine($"  FTS5 available  : {hasFts5}");
            Console.WriteLine($"  FTS5 create OK  : {fts5Created}");

            if (probe.TryGetProperty("fts5Error", out var fts5Error) &&
                fts5Error.ValueKind == JsonValueKind.String)
            {
                Console.WriteLine($"  FTS5 error      : {fts5Error.GetString()}");
            }

            if (!fts5Created)
            {
                // The decisive failure. Everything downstream depends on it, so
                // stop here rather than emit confusing follow-on errors.
                failures.Add("FTS5 is NOT available in the linked SQLite — Mozz search cannot work on this platform as built");
                Report(failures);
                return 1;
            }

            var dbPath = Path.Combine(Path.GetTempPath(), $"mozz-spike-{Guid.NewGuid():N}.sqlite");

            Console.WriteLine();
            Console.WriteLine($"=== 2. Benchmark: generate {trackCount:N0} tracks and measure reads ===");
            var benchmark = Native.Benchmark(dbPath, trackCount);
            var metrics = benchmark.GetProperty("metrics");

            var searchP95 = metrics.GetProperty("searchP95Ms").GetDouble();
            var searchP50 = metrics.GetProperty("searchP50Ms").GetDouble();
            var coldOpen = metrics.GetProperty("coldOpenMs").GetDouble();
            var pageFetch = metrics.GetProperty("pageFetchMs").GetDouble();
            var generation = metrics.GetProperty("generationSeconds").GetDouble();

            Console.WriteLine(benchmark.GetProperty("summary").GetString());
            Console.WriteLine();
            Console.WriteLine("  metric                 this platform      iOS (iPhone 17 Pro Max)");
            Console.WriteLine($"  search p50             {searchP50,10:F1} ms      {7.9,10:F1} ms");
            Console.WriteLine($"  search p95             {searchP95,10:F1} ms      {IosSearchP95Ms,10:F1} ms");
            Console.WriteLine($"  cold open + count      {coldOpen,10:F1} ms      {IosColdOpenMs,10:F1} ms");
            Console.WriteLine($"  page fetch (100 rows)  {pageFetch,10:F1} ms      {IosPageFetchMs,10:F1} ms");
            Console.WriteLine($"  generation             {generation,10:F1} s       {3.9,10:F1} s");

            if (searchP95 > SearchP95BudgetMs)
            {
                failures.Add($"search p95 {searchP95:F1} ms exceeds the {SearchP95BudgetMs:F0} ms product budget");
            }

            Console.WriteLine();
            Console.WriteLine("=== 3. Marshalling cost: DB time vs JSON encode time at the boundary ===");
            Console.WriteLine("    (open time is listed separately — this entry point is stateless and");
            Console.WriteLine("     reopens the DB per call, so it must not inflate the query baseline)");
            string[] terms = ["Machine", "Golden", "Ocean", "Silent", "Horizon"];
            double totalQuery = 0, totalEncode = 0;

            foreach (var term in terms)
            {
                var search = Native.Search(dbPath, term, 100);
                var openMs = search.GetProperty("openMs").GetDouble();
                var queryMs = search.GetProperty("queryMs").GetDouble();
                var encodeMs = search.GetProperty("encodeMs").GetDouble();
                var bytes = search.GetProperty("payloadBytes").GetInt32();
                var tracks = search.GetProperty("tracks").GetInt32();

                totalQuery += queryMs;
                totalEncode += encodeMs;
                Console.WriteLine(
                    $"  {term,-10} {tracks,4} tracks   open {openMs,6:F2} ms   query {queryMs,7:F2} ms   " +
                    $"encode {encodeMs,6:F2} ms   {bytes,6} bytes");
            }

            var encodeShare = totalQuery > 0 ? totalEncode / totalQuery * 100 : 0;
            Console.WriteLine();
            Console.WriteLine($"  encode overhead: {encodeShare:F1}% of query time " +
                              $"({totalEncode:F2} ms encode vs {totalQuery:F2} ms query)");
            Console.WriteLine(encodeShare < 25
                ? "  => JSON at the boundary is cheap. The coarse-grained design holds."
                : "  => encode cost is significant; consider a binary boundary format.");

            try { File.Delete(dbPath); } catch { /* best effort */ }
        }
        catch (DllNotFoundException error)
        {
            failures.Add($"could not load the MozzFFI shared library: {error.Message}");
        }
        catch (Exception error)
        {
            failures.Add($"{error.GetType().Name}: {error.Message}");
        }

        Report(failures);
        return failures.Count == 0 ? 0 : 1;
    }

    private static void Report(List<string> failures)
    {
        Console.WriteLine();
        if (failures.Count == 0)
        {
            Console.WriteLine("RESULT: PASS — the Swift core builds, loads and runs through a C ABI on this platform.");
            return;
        }

        Console.WriteLine("RESULT: FAIL");
        foreach (var failure in failures)
        {
            Console.WriteLine($"  - {failure}");
        }
    }
}

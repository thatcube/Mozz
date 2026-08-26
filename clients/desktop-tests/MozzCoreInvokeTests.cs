using System.Reflection;
using System.Runtime.InteropServices;
using Google.Protobuf;
using Mozz.Desktop.Core;
using Mozz.V1;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// The typed command path, driven against the real Swift library.
///
/// Everything else in this project runs without the core. This one cannot: the
/// thing under test is the marshalling — an <c>unsafe byte*</c> LibraryImport, a
/// fixed block, and a span copied out before Swift's allocation is released.
/// None of that can be checked with a stand-in, because a stand-in is exactly
/// where such a bug would hide.
///
/// Requires <c>swift build -c release --product MozzFFI</c>, so CI runs these
/// in a second pass after the Swift build rather than in the early fast pass
/// with everything else. They fail loudly when the library is missing: a test
/// that quietly skips itself is a test that stops being run and nobody notices.
/// </summary>
public class MozzCoreInvokeTests
{
    private static readonly string? LibraryPath = FindLibrary();

    static MozzCoreInvokeTests()
    {
        if (LibraryPath is null) return;
        NativeLibrary.SetDllImportResolver(
            typeof(MozzCore).Assembly,
            (name, _, _) => name == "MozzFFI" ? NativeLibrary.Load(LibraryPath) : IntPtr.Zero);
    }

    private static string? FindLibrary()
    {
        var extension = OperatingSystem.IsWindows() ? "dll"
            : OperatingSystem.IsMacOS() ? "dylib" : "so";
        var name = OperatingSystem.IsWindows() ? $"MozzFFI.{extension}" : $"libMozzFFI.{extension}";

        var directory = AppContext.BaseDirectory;
        for (var i = 0; i < 8 && directory is not null; i++)
        {
            foreach (var configuration in new[] { "release", "debug" })
            {
                var candidate = Path.Combine(directory, ".build", configuration, name);
                if (File.Exists(candidate)) return candidate;
            }
            directory = Path.GetDirectoryName(directory);
        }
        return null;
    }

    private static void RequireLibrary()
    {
        Assert.True(
            LibraryPath is not null,
            "libMozzFFI was not found. Build it first: "
            + "swift build -c release --product MozzFFI");
    }

    private static MozzCore OpenTemporaryLibrary(out string root)
    {
        root = Path.Combine(Path.GetTempPath(), "mozz-invoke-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var core = new MozzCore();
        core.Open(Path.Combine(root, "library.sqlite"));
        return core;
    }

    /// <summary>
    /// The reason this path exists at all: a request carrying a zero byte.
    ///
    /// A <c>libraries</c> request is an empty message inside the command oneof,
    /// so it encodes as 08 03 52 00. Through <c>mozz_session_call</c> — which
    /// marshals a null-terminated string — that arrives as 08 03 52 and does not
    /// parse. If the marshalling here is wrong in the same way, this is where it
    /// shows.
    /// </summary>
    [Fact]
    public void ARequestContainingAZeroByteSurvivesMarshalling()
    {
        RequireLibrary();

        using var core = OpenTemporaryLibrary(out var root);
        try
        {
            var request = new Request { Id = 3, Libraries = new LibrariesRequest() };
            Assert.Contains((byte)0, request.ToByteArray());

            var response = core.Invoke(request);

            Assert.Equal(3ul, response.Id);
            Assert.Equal(Response.ResultOneofCase.Libraries, response.ResultCase);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    /// <summary>
    /// An empty library is a legitimate answer, not an error — a fresh install
    /// has no servers attached yet.
    /// </summary>
    [Fact]
    public void AnEmptyLibraryReturnsNoServersRatherThanFailing()
    {
        RequireLibrary();

        using var core = OpenTemporaryLibrary(out var root);
        try
        {
            var response = core.Invoke(new Request { Id = 1, Libraries = new LibrariesRequest() });

            Assert.Equal(Response.ResultOneofCase.Libraries, response.ResultCase);
            Assert.Empty(response.Libraries.Libraries);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    /// <summary>
    /// A failure from the core arrives as a variant of the response, and must
    /// surface here as the same exception every other call path throws — not as
    /// a silently empty result.
    /// </summary>
    [Fact]
    public void AFailureVariantBecomesAnException()
    {
        RequireLibrary();

        using var core = OpenTemporaryLibrary(out var root);
        try
        {
            var request = new Request
            {
                Id = 9,
                Artist = new ArtistRequest { ServerId = "nope", RemoteId = "also-nope" },
            };

            var error = Assert.Throws<MozzCoreException>(() => core.Invoke(request));
            Assert.Contains("also-nope", error.Message);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    /// <summary>
    /// Repeated calls must not leak or corrupt: each response is copied out of
    /// Swift's buffer and that buffer released before the next call.
    /// </summary>
    [Fact]
    public void ManyCallsInARowStayCorrect()
    {
        RequireLibrary();

        using var core = OpenTemporaryLibrary(out var root);
        try
        {
            for (var i = 1; i <= 50; i++)
            {
                var response = core.Invoke(
                    new Request { Id = (ulong)i, Libraries = new LibrariesRequest() });
                Assert.Equal((ulong)i, response.Id);
            }
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

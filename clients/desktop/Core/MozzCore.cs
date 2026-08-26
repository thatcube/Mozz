using Google.Protobuf;
using Mozz.V1;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Mozz.Desktop.Core;

/// <summary>
/// The bridge to the Swift core.
///
/// Everything the app knows about a music library comes through here: the
/// database, the provider clients, sync and search are all Swift, compiled to a
/// native library and reached over a C ABI. This class is the only place in the
/// app that knows that.
///
/// The shape is one command dispatcher rather than dozens of exported symbols,
/// so adding a capability is a new request here and a new case in Swift — with
/// no P/Invoke declaration to keep in step across two toolchains.
/// </summary>
public sealed partial class MozzCore : IDisposable
{
    // SwiftPM emits MozzFFI.dll on Windows, libMozzFFI.dylib on macOS and
    // libMozzFFI.so on Linux. .NET's probing adds the prefix and extension, so
    // the bare name is correct on all three.
    private const string Library = "MozzFFI";

    [LibraryImport(Library)]
    private static partial long mozz_session_open(nint dbPath);

    [LibraryImport(Library)]
    private static partial int mozz_session_close(long handle);

    [LibraryImport(Library)]
    private static partial nint mozz_session_call(long handle, nint requestJson);

    [LibraryImport(Library)]
    private static partial void mozz_ffi_free_string(nint pointer);

    // The schema-described command surface, which needs its own pair because
    // protobuf cannot travel as a C string: encoded messages contain 0x00
    // freely and a string ends at the first one. Not theoretical here — a
    // `libraries` request encodes as 08 03 52 00, so the simplest command in
    // the schema would arrive truncated. Length in, length out instead.
    [LibraryImport(Library)]
    private static unsafe partial byte* mozz_session_invoke(
        long handle, byte* request, int requestLength, int* responseLength);

    // Deliberately not mozz_ffi_free_string: that releases a null-terminated
    // CChar buffer, this releases raw bytes. Freeing either through the other
    // is undefined, so the two stay visibly separate.
    [LibraryImport(Library)]
    private static unsafe partial void mozz_session_free_bytes(byte* pointer);

    private long _handle;
    private bool _disposed;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public bool IsOpen => _handle > 0;

    /// <summary>
    /// Open a library file, creating it if absent — a fresh install is an empty
    /// database rather than an error.
    /// </summary>
    public void Open(string databasePath)
    {
        Close();
        var utf8 = Marshal.StringToCoTaskMemUTF8(databasePath);
        try
        {
            _handle = mozz_session_open(utf8);
        }
        finally
        {
            Marshal.FreeCoTaskMem(utf8);
        }

        if (_handle <= 0)
        {
            throw new InvalidOperationException($"Could not open the library at {databasePath}");
        }
    }

    public void Close()
    {
        if (_handle > 0)
        {
            mozz_session_close(_handle);
            _handle = 0;
        }
    }

    /// <summary>
    /// Send one command and decode its payload. Synchronous by nature, because
    /// the C ABI is; callers keep it off the UI thread via <see cref="CallAsync"/>.
    /// </summary>
    public T? Call<T>(object request)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_handle <= 0)
        {
            throw new InvalidOperationException("No library is open");
        }

        var json = JsonSerializer.Serialize(request, JsonOptions);
        var utf8 = Marshal.StringToCoTaskMemUTF8(json);
        nint responsePtr = 0;
        try
        {
            responsePtr = mozz_session_call(_handle, utf8);
            if (responsePtr == 0)
            {
                throw new InvalidOperationException("The core returned nothing");
            }

            var text = Marshal.PtrToStringUTF8(responsePtr)
                       ?? throw new InvalidOperationException("Unreadable response");

            var envelope = JsonSerializer.Deserialize<Envelope<T>>(text, JsonOptions)
                           ?? throw new InvalidOperationException("Unreadable response envelope");

            if (!envelope.Ok)
            {
                throw new MozzCoreException(envelope.Error ?? "unknown error");
            }

            return envelope.Payload;
        }
        finally
        {
            // Every buffer the core hands back is ours to release, exactly once.
            if (responsePtr != 0) mozz_ffi_free_string(responsePtr);
            Marshal.FreeCoTaskMem(utf8);
        }
    }

    /// <summary>
    /// Run a command on the thread pool.
    ///
    /// The Swift side parks a thread while it awaits, so calling it on the UI
    /// thread would freeze the window for the length of a query. Every read from
    /// a view model goes through here.
    /// </summary>
    public Task<T?> CallAsync<T>(object request, CancellationToken token = default)
        => Task.Run(() => Call<T>(request), token);

    /// <summary>
    /// Send one schema-described command and get its response back.
    ///
    /// The typed counterpart to <see cref="Call{T}"/>: the request and response
    /// are generated from <c>schema/</c>, so a command this build does not know
    /// about cannot be constructed, and a field cannot quietly change shape
    /// underneath the caller. That is the whole point — the four parity bugs
    /// this replaces were all a capability existing in the core with nothing on
    /// this side able to see it.
    ///
    /// Failures arrive as a <c>Failure</c> variant of the response rather than
    /// as a thrown error from Swift, because a thrown error across a C ABI is a
    /// crash. This translates that variant into an exception so callers here can
    /// use the same try/catch they already do.
    /// </summary>
    public Response Invoke(Request request)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_handle <= 0)
        {
            throw new InvalidOperationException("No library is open");
        }

        var bytes = request.ToByteArray();
        var response = InvokeRaw(bytes);

        if (response.ResultCase == Response.ResultOneofCase.Failure)
        {
            throw new MozzCoreException(response.Failure.Message);
        }

        return response;
    }

    public Task<Response> InvokeAsync(Request request, CancellationToken token = default)
        => Task.Run(() => Invoke(request), token);

    private unsafe Response InvokeRaw(byte[] request)
    {
        int length;
        byte* responsePtr;

        fixed (byte* requestPtr = request)
        {
            responsePtr = mozz_session_invoke(_handle, requestPtr, request.Length, &length);
        }

        if (responsePtr is null)
        {
            throw new InvalidOperationException("The core returned nothing");
        }

        try
        {
            // Copy before releasing: the span points at Swift's allocation, and
            // the parsed message must not outlive it.
            return Response.Parser.ParseFrom(new ReadOnlySpan<byte>(responsePtr, length));
        }
        finally
        {
            mozz_session_free_bytes(responsePtr);
        }
    }

    /// <summary>
    /// A listing plus where to resume it. The cursor rides the envelope rather
    /// than the payload, so <see cref="Call{T}"/> stays usable for everything
    /// that does not page.
    /// </summary>
    public Page<T> CallPage<T>(object request)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_handle <= 0) throw new InvalidOperationException("No library is open");

        var json = JsonSerializer.Serialize(request, JsonOptions);
        var utf8 = Marshal.StringToCoTaskMemUTF8(json);
        nint responsePtr = 0;
        try
        {
            responsePtr = mozz_session_call(_handle, utf8);
            if (responsePtr == 0) throw new InvalidOperationException("The core returned nothing");

            var text = Marshal.PtrToStringUTF8(responsePtr)
                       ?? throw new InvalidOperationException("Unreadable response");
            var envelope = JsonSerializer.Deserialize<Envelope<T>>(text, JsonOptions)
                           ?? throw new InvalidOperationException("Unreadable response envelope");
            if (!envelope.Ok) throw new MozzCoreException(envelope.Error ?? "unknown error");

            return new Page<T>(envelope.Payload, envelope.NextCursor);
        }
        finally
        {
            if (responsePtr != 0) mozz_ffi_free_string(responsePtr);
            Marshal.FreeCoTaskMem(utf8);
        }
    }

    public Task<Page<T>> CallPageAsync<T>(object request, CancellationToken token = default)
        => Task.Run(() => CallPage<T>(request), token);

    public void Dispose()
    {
        if (_disposed) return;
        Close();
        _disposed = true;
        GC.SuppressFinalize(this);
    }

    private sealed record Envelope<T>(
        [property: JsonPropertyName("ok")] bool Ok,
        [property: JsonPropertyName("cmd")] string? Cmd,
        [property: JsonPropertyName("payload")] T? Payload,
        [property: JsonPropertyName("error")] string? Error,
        [property: JsonPropertyName("id")] int? Id,
        [property: JsonPropertyName("nextCursor")] string? NextCursor);
}

/// <summary>An error reported by the Swift core rather than by interop.</summary>
public sealed class MozzCoreException(string message) : Exception(message);

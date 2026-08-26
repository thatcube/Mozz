using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Mozz.Desktop.Audio.Native;

/// <summary>
/// The raw P/Invoke surface of the shared Rust audio engine (audio/ffi),
/// plus the glue that lets the engine read a managed
/// <see cref="Streaming.ByteStreamSource"/> through its C callbacks.
///
/// Nothing above this file knows the engine is native, exactly as
/// <c>MozzCore</c> is the only file that knows the core is. Everything here is
/// a faithful transcription of audio/ffi/include/mozz_audio.h — when that
/// header changes, this changes with it.
/// </summary>
internal static unsafe class MozzAudioInterop
{
    // The cdylib is libmozz_audio_ffi.dylib / .so / mozz_audio_ffi.dll. .NET's
    // loader adds the platform prefix and suffix, so the name here is bare.
    // tools/build-audio-cdylib.sh builds it and the .csproj copies it next to
    // the app, which is where the loader looks first.
    private const string Library = "mozz_audio_ffi";

    /// <summary>
    /// The C <c>MozzSource</c>: an opaque context plus three function pointers.
    /// Passed to the engine by value; the engine keeps the pointers and calls
    /// them from its decode thread until it calls <c>close</c> exactly once.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct MozzSource
    {
        public nint Ctx;
        public nint Read;
        public nint Seek;
        public nint Close;
    }

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern nint mozz_player_new(uint sample_rate, ushort channels, nuint capacity_frames);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_free(nint player);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_play_now(
        nint player, MozzSource source, nint extension, ulong track, double gain_db,
        [MarshalAs(UnmanagedType.U1)] bool has_gain);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_play_next(
        nint player, MozzSource source, nint extension, ulong track, double gain_db,
        [MarshalAs(UnmanagedType.U1)] bool has_gain);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_pause(nint player);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_resume(nint player);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_stop(nint player);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_seek(nint player, double seconds);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern uint mozz_player_state(nint player);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern double mozz_player_position_seconds(nint player);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong mozz_player_current_track(nint player);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.U1)]
    internal static extern bool mozz_player_has_failed(nint player);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_set_equalizer(
        nint player, double* gains_db, double preamp_db,
        [MarshalAs(UnmanagedType.U1)] bool enabled);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_set_replay_gain(nint player, uint mode, double preamp_db);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mozz_player_set_volume(nint player, double volume);

    // --- Callback glue -----------------------------------------------------
    //
    // The three callbacks are STATIC function pointers, not delegates. That is
    // deliberate and is the whole answer to "keep the delegate alive": a static
    // [UnmanagedCallersOnly] method has a fixed native entry point that the GC
    // can never move or collect, so there is no delegate to root and no way for
    // a collected thunk to crash the decode thread. What *does* need rooting is
    // the managed ByteStreamSource; we pin it with a GCHandle and hand its
    // IntPtr to the engine as the callback context. The handle is released in
    // CloseTrampoline — see Attach.

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static nint ReadTrampoline(nint ctx, byte* buffer, nuint length)
    {
        try
        {
            if (GCHandle.FromIntPtr(ctx).Target is not Streaming.ByteStreamSource source)
                return -1;
            int want = length > int.MaxValue ? int.MaxValue : (int)length;
            return source.Read(new Span<byte>(buffer, want));
        }
        catch
        {
            // An exception must never cross back into Rust; report an error the
            // engine already knows how to handle.
            return -1;
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static long SeekTrampoline(nint ctx, long offset, int whence)
    {
        try
        {
            if (GCHandle.FromIntPtr(ctx).Target is not Streaming.ByteStreamSource source)
                return -1;
            return source.Seek(offset, whence);
        }
        catch
        {
            return -1;
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void CloseTrampoline(nint ctx)
    {
        // Called exactly once, from the decode thread, when the engine is done
        // with the stream. Close the source and free the GCHandle here — not
        // before — so the source stays alive for as long as Rust might read it.
        var handle = GCHandle.FromIntPtr(ctx);
        try
        {
            (handle.Target as Streaming.ByteStreamSource)?.Close();
        }
        catch
        {
            // Closing must not throw across the boundary.
        }
        finally
        {
            handle.Free();
        }
    }

    /// <summary>
    /// Root <paramref name="source"/> and wrap it in a <see cref="MozzSource"/>
    /// the engine can call. The GCHandle allocated here is freed by
    /// CloseTrampoline when the engine finishes with the stream, so this must
    /// only be called for a source that is about to be handed to a live player;
    /// a source that is attached but never played would leak its handle.
    /// </summary>
    internal static MozzSource Attach(Streaming.ByteStreamSource source)
    {
        var handle = GCHandle.Alloc(source);
        return new MozzSource
        {
            Ctx = GCHandle.ToIntPtr(handle),
            Read = (nint)(delegate* unmanaged[Cdecl]<nint, byte*, nuint, nint>)&ReadTrampoline,
            Seek = (nint)(delegate* unmanaged[Cdecl]<nint, long, int, long>)&SeekTrampoline,
            Close = (nint)(delegate* unmanaged[Cdecl]<nint, void>)&CloseTrampoline,
        };
    }
}

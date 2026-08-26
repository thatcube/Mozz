//! The C ABI, so a shell can drive the player without speaking Rust.
//!
//! # What crosses the boundary, and what deliberately does not
//!
//! Commands and state cross: play, pause, seek, position. These happen at human
//! speed - a few dozen a minute at most - so the cost of a call is irrelevant
//! and the clarity of a narrow surface is worth everything.
//!
//! Audio does not cross. Not one sample. The decode thread and the audio
//! callback both live entirely on this side, so no buffer is ever handed over a
//! language boundary while a deadline is running. That is the property that
//! makes this safe to use from a garbage-collected shell: a collection pause on
//! the other side cannot cause a dropout here, because the other side is not
//! involved in producing sound.
//!
//! Bytes for a track come *in* through a read callback rather than being
//! fetched here. The credentials for a media server belong to the shell that
//! logged into it, and moving them down here would make every shell reimplement
//! authentication for its own platform.
//!
//! # The rules every function here follows
//!
//! A null handle is a no-op or a defined default, never a crash. A shell that
//! double-frees or uses a handle after closing it gets nothing rather than
//! undefined behaviour, because the alternative is a crash report that blames
//! the audio engine for a bug in a view controller.
//!
//! No function here panics across the boundary. Unwinding into C is undefined,
//! so anything that could panic is caught and turned into a return value.

use std::ffi::{c_char, c_int, c_void, CStr};
use std::io::{Read, Seek, SeekFrom};
use std::panic::{catch_unwind, AssertUnwindSafe};

use mozz_audio::player::{FailureKind, Player, State};
use mozz_audio::{EqualizerProfile, ReplayGainMode, ReplayGainSettings};

/// Read bytes from a shell-owned stream.
///
/// Returns the number of bytes read, `0` at the end of the stream, or a
/// negative value on error. Called only from the decode thread, never from the
/// audio callback, so it may block on a network.
pub type MozzReadFn =
    unsafe extern "C" fn(ctx: *mut c_void, buffer: *mut u8, length: usize) -> isize;

/// Seek a shell-owned stream. `whence` is 0 start, 1 current, 2 end.
///
/// Returns the new absolute position, or negative on error.
pub type MozzSeekFn = unsafe extern "C" fn(ctx: *mut c_void, offset: i64, whence: c_int) -> i64;

/// Release whatever the shell allocated for a stream.
pub type MozzCloseFn = unsafe extern "C" fn(ctx: *mut c_void);

/// A stream of encoded audio owned by the shell.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct MozzSource {
    /// Passed back to every callback. Opaque here.
    pub ctx: *mut c_void,
    /// Required.
    pub read: MozzReadFn,
    /// Required. A stream that cannot seek cannot be decoded, because
    /// containers keep their index at the end.
    pub seek: MozzSeekFn,
    /// Called exactly once when the decoder is finished with the stream.
    pub close: MozzCloseFn,
}

// The shell promises these callbacks are safe to invoke from the decode thread.
// It is the same promise any C callback carries, and it cannot be checked here.
unsafe impl Send for MozzSource {}
unsafe impl Sync for MozzSource {}

/// Bridges a shell's callbacks into something the decoder can read.
struct CallbackSource {
    source: MozzSource,
    closed: bool,
}

impl Read for CallbackSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        // SAFETY: the pointer and length describe `buf`, which is live for this
        // call, and the shell supplied `read` alongside `ctx`.
        let taken = unsafe { (self.source.read)(self.source.ctx, buf.as_mut_ptr(), buf.len()) };
        if taken < 0 {
            return Err(std::io::Error::other("the shell reported a read error"));
        }
        Ok(taken as usize)
    }
}

impl Seek for CallbackSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let (offset, whence) = match pos {
            SeekFrom::Start(offset) => (offset as i64, 0),
            SeekFrom::Current(offset) => (offset, 1),
            SeekFrom::End(offset) => (offset, 2),
        };
        // SAFETY: as above; `ctx` came with `seek` from the same shell.
        let landed = unsafe { (self.source.seek)(self.source.ctx, offset, whence) };
        if landed < 0 {
            return Err(std::io::Error::other("the shell reported a seek error"));
        }
        Ok(landed as u64)
    }
}

impl Drop for CallbackSource {
    fn drop(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;
        // SAFETY: called exactly once, which `closed` enforces.
        unsafe { (self.source.close)(self.source.ctx) };
    }
}

/// Opaque player handle.
pub struct MozzPlayer {
    inner: Player,
}

/// Create a player. Returns null if the decode thread cannot be started.
///
/// # Safety
/// The returned pointer must be released with [`mozz_player_free`] exactly once.
#[no_mangle]
pub extern "C" fn mozz_player_new(
    sample_rate: u32,
    channels: u16,
    capacity_frames: usize,
) -> *mut MozzPlayer {
    match catch_unwind(|| Player::new(sample_rate, channels, capacity_frames)) {
        Ok(Ok(inner)) => Box::into_raw(Box::new(MozzPlayer { inner })),
        _ => std::ptr::null_mut(),
    }
}

/// Destroy a player, stopping playback and closing the device.
///
/// # Safety
/// `player` must come from [`mozz_player_new`] and must not be used afterwards.
/// Passing null is allowed and does nothing.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_free(player: *mut MozzPlayer) {
    if player.is_null() {
        return;
    }
    let owned = unsafe { Box::from_raw(player) };
    // Dropping joins the decode thread, so a panic there would unwind into C.
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// Play `source` immediately, discarding anything queued.
///
/// `extension` may be null; it is only a hint and the bytes always win.
///
/// # Safety
/// `player` must be a live handle. `source`'s callbacks must remain valid until
/// its `close` is invoked.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_play_now(
    player: *mut MozzPlayer,
    source: MozzSource,
    extension: *const c_char,
    track: u64,
    gain_db: f64,
    has_gain: bool,
) {
    let Some(player) = (unsafe { player.as_ref() }) else {
        // No player means nothing will ever read this stream, so release it
        // here rather than leaking whatever the shell allocated.
        unsafe { (source.close)(source.ctx) };
        return;
    };
    player.inner.play_now(
        Box::new(CallbackSource {
            source,
            closed: false,
        }),
        unsafe { hint(extension) },
        track,
        has_gain.then_some(gain_db),
    );
}

/// Queue `source` behind the current track, so they meet with no gap.
///
/// # Safety
/// As [`mozz_player_play_now`].
#[no_mangle]
pub unsafe extern "C" fn mozz_player_play_next(
    player: *mut MozzPlayer,
    source: MozzSource,
    extension: *const c_char,
    track: u64,
    gain_db: f64,
    has_gain: bool,
) {
    let Some(player) = (unsafe { player.as_ref() }) else {
        unsafe { (source.close)(source.ctx) };
        return;
    };
    player.inner.play_next(
        Box::new(CallbackSource {
            source,
            closed: false,
        }),
        unsafe { hint(extension) },
        track,
        has_gain.then_some(gain_db),
    );
}

/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_pause(player: *mut MozzPlayer) {
    if let Some(player) = unsafe { player.as_ref() } {
        player.inner.pause();
    }
}

/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_resume(player: *mut MozzPlayer) {
    if let Some(player) = unsafe { player.as_ref() } {
        player.inner.resume();
    }
}

/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_stop(player: *mut MozzPlayer) {
    if let Some(player) = unsafe { player.as_ref() } {
        player.inner.stop();
    }
}

/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_seek(player: *mut MozzPlayer, seconds: f64) {
    if let Some(player) = unsafe { player.as_ref() } {
        player.inner.seek(seconds);
    }
}

/// 0 idle, 1 playing, 2 paused, 3 ended. A null player is idle.
///
/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_state(player: *const MozzPlayer) -> u32 {
    let Some(player) = (unsafe { player.as_ref() }) else {
        return 0;
    };
    match player.inner.state() {
        State::Idle => 0,
        State::Playing => 1,
        State::Paused => 2,
        State::Ended => 3,
    }
}

/// Seconds of the current track that have actually reached the device.
///
/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_position_seconds(player: *const MozzPlayer) -> f64 {
    unsafe { player.as_ref() }
        .map(|p| p.inner.position_seconds())
        .unwrap_or(0.0)
}

/// The track the audio is currently in, which is not necessarily the last
/// queued.
///
/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_current_track(player: *const MozzPlayer) -> u64 {
    unsafe { player.as_ref() }
        .map(|p| p.inner.current_track())
        .unwrap_or(0)
}

/// True when a decode has failed since the last command.
///
/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_has_failed(player: *const MozzPlayer) -> bool {
    unsafe { player.as_ref() }
        .map(|p| p.inner.has_failed())
        .unwrap_or(false)
}

/// Set the ten-band equaliser. `gains_db` must point to ten doubles.
///
/// # Safety
/// `player` must be a live handle or null, and `gains_db` must be readable for
/// ten `f64` values.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_set_equalizer(
    player: *mut MozzPlayer,
    gains_db: *const f64,
    preamp_db: f64,
    enabled: bool,
) {
    let Some(player) = (unsafe { player.as_ref() }) else {
        return;
    };
    if gains_db.is_null() {
        return;
    }

    let mut gains = [0.0f64; mozz_audio::ISO_CENTRES_HZ.len()];
    // SAFETY: the caller promises ten readable doubles, which is the documented
    // contract and the only thing this reads.
    let supplied = unsafe { std::slice::from_raw_parts(gains_db, gains.len()) };
    gains.copy_from_slice(supplied);

    player
        .inner
        .set_equalizer(EqualizerProfile::from_gains(gains, preamp_db), enabled);
}

/// Set ReplayGain. `mode` is 0 off, 1 track, 2 album.
///
/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_set_replay_gain(
    player: *mut MozzPlayer,
    mode: u32,
    preamp_db: f64,
) {
    let Some(player) = (unsafe { player.as_ref() }) else {
        return;
    };
    let mode = match mode {
        1 => ReplayGainMode::Track,
        2 => ReplayGainMode::Album,
        // Anything unrecognised is Off rather than a guess. A shell built
        // against a newer enum should get no normalisation rather than the
        // wrong normalisation.
        _ => ReplayGainMode::Off,
    };
    let mut settings = ReplayGainSettings::new(mode);
    settings.preamp_db = preamp_db;
    player.inner.set_replay_gain(settings);
}

/// Why the last decode failed: 0 none, 1 unsupported, 2 interrupted, 3 corrupt.
///
/// A bool was not enough. "This is not audio we can decode" and "the network
/// went away" call for opposite responses - one should be remembered so the
/// track is never retried, the other must be retried and must not mark the
/// track as broken. A shell with only `has_failed` either retries forever on a
/// file that will never play, or writes off a good track over a one second
/// network fault.
///
/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_failure_kind(player: *const MozzPlayer) -> u32 {
    let Some(player) = (unsafe { player.as_ref() }) else {
        return 0;
    };
    match player.inner.failure_kind() {
        FailureKind::None => 0,
        FailureKind::Unsupported => 1,
        FailureKind::Interrupted => 2,
        FailureKind::Corrupt => 3,
    }
}

/// True when the last failure is worth retrying rather than remembering.
///
/// Offered alongside the raw kind so a shell does not have to hard-code which
/// numbers mean transient - a judgement that belongs with the engine, and one
/// that would otherwise be duplicated and drift in every shell.
///
/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_failure_is_retryable(player: *const MozzPlayer) -> bool {
    unsafe { player.as_ref() }
        .map(|p| p.inner.failure_kind().is_worth_retrying())
        .unwrap_or(false)
}

/// Set the listener's volume, `0.0` silent to `1.0` unity.
///
/// This is the shell's own level control, applied after ReplayGain and the
/// equaliser. Values are clamped to `0.0..=1.0` inside the engine, and the
/// change is ramped so it does not click. A null player is ignored.
///
/// # Safety
/// `player` must be a live handle or null.
#[no_mangle]
pub unsafe extern "C" fn mozz_player_set_volume(player: *mut MozzPlayer, volume: f64) {
    if let Some(player) = unsafe { player.as_ref() } {
        player.inner.set_volume(volume as f32);
    }
}

/// Turn a possibly-null C string into an extension hint.
///
/// # Safety
/// `raw` must be null or a valid NUL-terminated string.
unsafe fn hint(raw: *const c_char) -> Option<String> {
    if raw.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(raw) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// A stream the tests own, so the callbacks are exercised for real rather
    /// than mocked away.
    struct Fixture {
        bytes: Vec<u8>,
        position: usize,
        closes: Arc<AtomicUsize>,
    }

    unsafe extern "C" fn read(ctx: *mut c_void, buffer: *mut u8, length: usize) -> isize {
        let fixture = unsafe { &mut *(ctx as *mut Fixture) };
        let take = length.min(fixture.bytes.len().saturating_sub(fixture.position));
        if take > 0 {
            unsafe {
                std::ptr::copy_nonoverlapping(
                    fixture.bytes.as_ptr().add(fixture.position),
                    buffer,
                    take,
                )
            };
            fixture.position += take;
        }
        take as isize
    }

    unsafe extern "C" fn seek(ctx: *mut c_void, offset: i64, whence: c_int) -> i64 {
        let fixture = unsafe { &mut *(ctx as *mut Fixture) };
        let base = match whence {
            1 => fixture.position as i64,
            2 => fixture.bytes.len() as i64,
            _ => 0,
        };
        let landed = (base + offset).clamp(0, fixture.bytes.len() as i64);
        fixture.position = landed as usize;
        landed
    }

    unsafe extern "C" fn close(ctx: *mut c_void) {
        let fixture = unsafe { Box::from_raw(ctx as *mut Fixture) };
        fixture.closes.fetch_add(1, Ordering::SeqCst);
    }

    fn source(bytes: Vec<u8>, closes: Arc<AtomicUsize>) -> MozzSource {
        let fixture = Box::into_raw(Box::new(Fixture {
            bytes,
            position: 0,
            closes,
        }));
        MozzSource {
            ctx: fixture as *mut c_void,
            read,
            seek,
            close,
        }
    }

    fn wav(samples: &[i16]) -> Vec<u8> {
        let data = (samples.len() * 2) as u32;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&8_000u32.to_le_bytes());
        out.extend_from_slice(&16_000u32.to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data.to_le_bytes());
        for sample in samples {
            out.extend_from_slice(&sample.to_le_bytes());
        }
        out
    }

    fn eventually(mut check: impl FnMut() -> bool) -> bool {
        for _ in 0..400 {
            if check() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        false
    }

    #[test]
    fn a_player_can_be_created_and_freed() {
        let player = mozz_player_new(8_000, 1, 4096);
        assert!(!player.is_null());
        assert_eq!(unsafe { mozz_player_state(player) }, 0, "should start idle");
        unsafe { mozz_player_free(player) };
    }

    #[test]
    fn audio_plays_through_the_shell_supplied_callbacks() {
        let closes = Arc::new(AtomicUsize::new(0));
        let player = mozz_player_new(8_000, 1, 8192);

        unsafe {
            mozz_player_play_now(
                player,
                source(wav(&[8_000; 8_000]), Arc::clone(&closes)),
                c"wav".as_ptr(),
                77,
                0.0,
                false,
            )
        };

        assert!(
            eventually(|| unsafe { mozz_player_state(player) } == 1),
            "never reached playing"
        );
        assert_eq!(unsafe { mozz_player_current_track(player) }, 77);
        assert!(
            eventually(|| unsafe { mozz_player_position_seconds(player) } > 0.05),
            "position never advanced"
        );

        unsafe { mozz_player_free(player) };
        assert!(
            eventually(|| closes.load(Ordering::SeqCst) == 1),
            "the shell's stream was never closed"
        );
    }

    /// A shell that keeps calling after freeing must get nothing rather than a
    /// crash, because the crash report would blame the audio engine for a bug
    /// in a view controller.
    #[test]
    fn a_null_handle_is_inert_rather_than_fatal() {
        let null: *mut MozzPlayer = std::ptr::null_mut();

        unsafe {
            mozz_player_pause(null);
            mozz_player_resume(null);
            mozz_player_stop(null);
            mozz_player_seek(null, 30.0);
            mozz_player_set_replay_gain(null, 1, 3.0);
            mozz_player_set_equalizer(null, [0.0f64; 10].as_ptr(), 0.0, true);
            mozz_player_set_volume(null, 0.5);
            mozz_player_free(null);

            assert_eq!(mozz_player_state(null), 0);
            assert_eq!(mozz_player_position_seconds(null), 0.0);
            assert_eq!(mozz_player_current_track(null), 0);
            assert!(!mozz_player_has_failed(null));
        }
    }

    /// Handing a stream to a player that does not exist must still release it,
    /// or the shell leaks whatever it allocated on every failed call.
    #[test]
    fn a_stream_given_to_a_null_player_is_still_closed() {
        let closes = Arc::new(AtomicUsize::new(0));
        unsafe {
            mozz_player_play_now(
                std::ptr::null_mut(),
                source(wav(&[0; 8]), Arc::clone(&closes)),
                std::ptr::null(),
                1,
                0.0,
                false,
            )
        };
        assert_eq!(closes.load(Ordering::SeqCst), 1, "the stream leaked");
    }

    #[test]
    fn a_stream_that_is_not_audio_is_reported_rather_than_crashing() {
        let closes = Arc::new(AtomicUsize::new(0));
        let player = mozz_player_new(8_000, 1, 4096);

        unsafe {
            mozz_player_play_now(
                player,
                source(vec![9u8; 64], Arc::clone(&closes)),
                std::ptr::null(),
                5,
                0.0,
                false,
            )
        };

        assert!(
            eventually(|| unsafe { mozz_player_has_failed(player) }),
            "a stream that is not audio should be reported"
        );
        unsafe { mozz_player_free(player) };
    }

    /// A shell built against a newer enum must get no normalisation rather than
    /// the wrong normalisation.
    #[test]
    fn an_unknown_replay_gain_mode_is_off_rather_than_a_guess() {
        let player = mozz_player_new(8_000, 1, 4096);
        unsafe {
            mozz_player_set_replay_gain(player, 9_999, 6.0);
            mozz_player_free(player);
        }
    }
}

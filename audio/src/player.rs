//! A player: the engine, a decode thread, and a device, driven by commands.
//!
//! [`Engine`] is a mechanism that must be pumped, which is fine for tests and
//! useless for a shell. This wraps it in the thread that does the pumping and a
//! channel to tell it what to do, so a caller's whole involvement is sending
//! commands and reading state.
//!
//! # Why commands rather than method calls
//!
//! The engine is owned by the decode thread and cannot be touched from
//! anywhere else. A mutex around it would work until the day a caller held it
//! while doing something slow and the ring drained underneath them. A channel
//! makes that impossible to write: there is nothing to hold.
//!
//! It also makes the ordering obvious. "Seek, then set the equaliser" arrives
//! in that order and is applied in that order, without anyone reasoning about
//! which lock is taken first.
//!
//! # What is deliberately not here
//!
//! Nothing fetches anything. The decode thread reads through a [`Source`] the
//! caller supplies, because the credentials for a media server live in the
//! shell that logged into it, and moving them down here to save a callback
//! would mean every shell reimplements authentication for its own platform -
//! which is the problem this crate exists to avoid.

use std::io::{Read, Seek};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use crate::decode::{AudioDecoder, DecodeError};
use crate::engine::{Engine, Pumped};
use crate::ring::{ring, Consumer};
use crate::sink::PlaybackObserver;
use crate::{EqualizerProfile, ReplayGainSettings};

/// Anything the decoder can read a track from.
///
/// A blanket bound rather than a concrete type so a shell can supply a file, a
/// buffer, or an authenticated HTTP stream without this crate knowing which.
pub trait Source: Read + Seek + Send + Sync + 'static {}
impl<T: Read + Seek + Send + Sync + 'static> Source for T {}

/// Why a decode failed, in the terms a caller has to act on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailureKind {
    /// Nothing has failed.
    None,
    /// Not something we can play. Permanent: retrying achieves nothing, and
    /// the track should be remembered as unplayable.
    Unsupported,
    /// The stream broke partway. Likely transient, so the track must be
    /// retried and must NOT be written off.
    Interrupted,
    /// The audio is malformed past the point decoding can continue.
    Corrupt,
}

impl FailureKind {
    fn of(error: &DecodeError) -> Self {
        match error {
            DecodeError::Unsupported(_) => Self::Unsupported,
            DecodeError::Interrupted(_) => Self::Interrupted,
            DecodeError::Corrupt(_) => Self::Corrupt,
        }
    }

    fn code(self) -> u64 {
        match self {
            Self::None => 0,
            Self::Unsupported => 1,
            Self::Interrupted => 2,
            Self::Corrupt => 3,
        }
    }

    fn from_code(code: u64) -> Self {
        match code {
            1 => Self::Unsupported,
            2 => Self::Interrupted,
            3 => Self::Corrupt,
            _ => Self::None,
        }
    }

    /// True when retrying could plausibly work.
    ///
    /// The whole reason this type exists rather than a bool.
    pub fn is_worth_retrying(self) -> bool {
        matches!(self, Self::Interrupted)
    }
}

/// What the player is doing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    /// Nothing loaded.
    Idle,
    /// Producing audio.
    Playing,
    /// Holding position, device stopped.
    Paused,
    /// The queue ran out.
    Ended,
}

impl State {
    fn code(self) -> u64 {
        match self {
            Self::Idle => 0,
            Self::Playing => 1,
            Self::Paused => 2,
            Self::Ended => 3,
        }
    }

    fn from_code(code: u64) -> Self {
        match code {
            1 => Self::Playing,
            2 => Self::Paused,
            3 => Self::Ended,
            _ => Self::Idle,
        }
    }
}

/// Something to do, sent to the decode thread.
enum Command {
    /// Play immediately, discarding anything queued.
    PlayNow {
        source: Box<dyn Source>,
        extension: Option<String>,
        track: u64,
        gain_db: Option<f64>,
    },
    /// Queue behind what is already playing, so the join is gapless.
    PlayNext {
        source: Box<dyn Source>,
        extension: Option<String>,
        track: u64,
        gain_db: Option<f64>,
    },
    Pause,
    Resume,
    Stop,
    Seek(f64),
    SetEqualizer(EqualizerProfile, bool),
    SetReplayGain(ReplayGainSettings),
    SetVolume(f32),
    Shutdown,
}

/// Everything a caller can observe, without touching the decode thread.
///
/// Atomics rather than a lock because these are read while audio is playing,
/// often on a UI timer, and a reader that can block the decode thread is a
/// reader that can cause a dropout.
struct Observable {
    state: AtomicU64,
    /// Frames handed to the device since the current track began.
    frames_played: AtomicU64,
    /// The track the audio is currently in.
    current_track: AtomicU64,
    sample_rate: AtomicU64,
    /// Set when a decode fails, so a shell can say what happened rather than
    /// showing a player that silently stopped.
    failed: AtomicBool,
    /// Why it failed: 0 none, 1 unsupported, 2 interrupted, 3 corrupt.
    ///
    /// A bool is not enough. "This is not audio we can decode" and "the network
    /// went away" call for opposite responses - one should be remembered so the
    /// track is never retried, the other must be retried and must not mark the
    /// track as broken. Collapsing them means either retrying forever on a file
    /// that will never play, or writing off a good track over a one second
    /// network fault.
    failure_kind: AtomicU64,
    /// Absolute ring frame at which the current track began.
    ///
    /// Position is the difference between this and the ring's read position,
    /// which is exact. Counting frames since a track was queued would be wrong
    /// by however much of the previous track was still waiting to be heard.
    track_start_frame: AtomicU64,
}

impl crate::sink::PlaybackObserver for Observable {
    /// Record what a read actually produced.
    ///
    /// Called by whatever is consuming the ring, because that - not the
    /// decoder, and not a wall clock - is what knows what has been heard.
    /// Touches only atomics, because on the device path this runs inside the
    /// audio callback.
    fn observe(&self, outcome: crate::ring::ReadOutcome) {
        if let Some(boundary) = outcome.boundary {
            self.current_track.store(boundary.track, Ordering::Relaxed);
            self.track_start_frame
                .store(boundary.frame, Ordering::Relaxed);
        }
        let start = self.track_start_frame.load(Ordering::Relaxed);
        self.frames_played
            .store(outcome.end_frame.saturating_sub(start), Ordering::Relaxed);
    }
}

/// A running player.
pub struct Player {
    commands: Sender<Command>,
    observable: Arc<Observable>,
    thread: Option<JoinHandle<()>>,
}

impl Player {
    /// Start a player writing to the default output device.
    ///
    /// `capacity_frames` is how far ahead the decoder may run. Larger survives
    /// a slower network; smaller makes a skip discard less work.
    pub fn new(sample_rate: u32, channels: u16, capacity_frames: usize) -> Result<Self, String> {
        let (producer, consumer) = ring(capacity_frames, channels as usize);
        let observable = Arc::new(Observable {
            state: AtomicU64::new(State::Idle.code()),
            frames_played: AtomicU64::new(0),
            current_track: AtomicU64::new(0),
            sample_rate: AtomicU64::new(sample_rate as u64),
            failed: AtomicBool::new(false),
            failure_kind: AtomicU64::new(0),
            track_start_frame: AtomicU64::new(0),
        });

        let (tx, rx) = std::sync::mpsc::channel();
        let engine = Engine::new(producer, channels as usize);

        let thread_observable = Arc::clone(&observable);
        let thread = std::thread::Builder::new()
            .name("mozz-decode".into())
            .spawn(move || {
                run(
                    engine,
                    consumer,
                    rx,
                    thread_observable,
                    sample_rate,
                    channels,
                )
            })
            .map_err(|e| format!("could not start the decode thread: {e}"))?;

        Ok(Self {
            commands: tx,
            observable,
            thread: Some(thread),
        })
    }

    /// Play a track now, discarding whatever was queued.
    pub fn play_now(
        &self,
        source: Box<dyn Source>,
        extension: Option<String>,
        track: u64,
        gain_db: Option<f64>,
    ) {
        self.send(Command::PlayNow {
            source,
            extension,
            track,
            gain_db,
        });
    }

    /// Queue a track behind the current one, so they meet with no gap.
    pub fn play_next(
        &self,
        source: Box<dyn Source>,
        extension: Option<String>,
        track: u64,
        gain_db: Option<f64>,
    ) {
        self.send(Command::PlayNext {
            source,
            extension,
            track,
            gain_db,
        });
    }

    /// Hold position and stop the device.
    pub fn pause(&self) {
        self.send(Command::Pause);
    }

    /// Continue from where [`Player::pause`] stopped.
    pub fn resume(&self) {
        self.send(Command::Resume);
    }

    /// Stop and discard the queue.
    pub fn stop(&self) {
        self.send(Command::Stop);
    }

    /// Move within the current track.
    pub fn seek(&self, seconds: f64) {
        self.send(Command::Seek(seconds));
    }

    /// Replace the equaliser settings without interrupting playback.
    pub fn set_equalizer(&self, profile: EqualizerProfile, enabled: bool) {
        self.send(Command::SetEqualizer(profile, enabled));
    }

    /// Replace the ReplayGain settings.
    pub fn set_replay_gain(&self, settings: ReplayGainSettings) {
        self.send(Command::SetReplayGain(settings));
    }

    /// Set the listener's volume, `0.0` silent to `1.0` unity.
    pub fn set_volume(&self, level: f32) {
        self.send(Command::SetVolume(level));
    }

    /// What the player is doing.
    pub fn state(&self) -> State {
        State::from_code(self.observable.state.load(Ordering::Relaxed))
    }

    /// Seconds of the current track that have actually reached the device.
    ///
    /// Counted from frames consumed rather than from a clock, so it describes
    /// what has been heard rather than what has been decoded. Those differ by
    /// the whole buffer, which is exactly the error a wall clock would make.
    pub fn position_seconds(&self) -> f64 {
        let rate = self.observable.sample_rate.load(Ordering::Relaxed).max(1);
        self.observable.frames_played.load(Ordering::Relaxed) as f64 / rate as f64
    }

    /// The track the audio is currently in, which is not necessarily the last
    /// one queued.
    pub fn current_track(&self) -> u64 {
        self.observable.current_track.load(Ordering::Relaxed)
    }

    /// True when a decode failed since the last command.
    pub fn has_failed(&self) -> bool {
        self.observable.failed.load(Ordering::Relaxed)
    }

    /// Why the last decode failed, or [`FailureKind::None`].
    pub fn failure_kind(&self) -> FailureKind {
        FailureKind::from_code(self.observable.failure_kind.load(Ordering::Relaxed))
    }

    fn send(&self, command: Command) {
        // A closed channel means the decode thread is gone, which happens only
        // during shutdown. Dropping the command is right; there is nothing left
        // to perform it.
        let _ = self.commands.send(command);
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
        if let Some(thread) = self.thread.take() {
            // Joining rather than detaching, so the device is closed before the
            // process moves on. A detached decode thread can outlive the player
            // and keep a device open that something else wants.
            let _ = thread.join();
        }
    }
}

/// The decode thread.
fn run(
    mut engine: Engine,
    consumer: Consumer,
    commands: Receiver<Command>,
    observable: Arc<Observable>,
    sample_rate: u32,
    channels: u16,
) {
    // A device is not guaranteed. There may be no sound card, or - far more
    // often - the device may refuse the source's sample rate, which the sink
    // reports rather than faking because playing 44.1 kHz audio at 48 kHz
    // shifts its pitch.
    //
    // When that happens the player still has to work. Something must consume
    // the ring or the decoder fills it, stalls, and the track never ends, so a
    // player with no device would hang rather than degrade. Output::Silent
    // consumes at exactly the rate the device would have, which keeps position,
    // track boundaries and end-of-track honest while making no noise.
    let mut output = match crate::sink::Sink::open_or_return(
        consumer,
        sample_rate,
        channels,
        Arc::clone(&observable) as Arc<dyn crate::sink::PlaybackObserver>,
    ) {
        Ok(sink) => Output::Device(sink),
        Err(consumer) => Output::Silent {
            consumer,
            started: std::time::Instant::now(),
            consumed: 0u64,
            scratch: vec![0.0; 1024 * channels as usize],
        },
    };

    // True between the decoder finishing a track and the last of that track
    // leaving the ring.
    let mut draining = false;

    loop {
        // Commands first and all of them, so a burst of skips is collapsed
        // before any decoding is done for tracks already superseded.
        loop {
            match commands.try_recv() {
                Ok(Command::Shutdown) | Err(TryRecvError::Disconnected) => return,
                Ok(command) => {
                    // Any command supersedes a drain in progress; the new
                    // instruction decides what the state is now.
                    draining = false;
                    output.restart_clock();
                    apply(&mut engine, &observable, output.device(), command);
                }
                Err(TryRecvError::Empty) => break,
            }
        }

        output.drain(sample_rate, channels, &observable);

        match engine.pump() {
            Ok(Pumped::Wrote(_)) => {}
            Ok(Pumped::Full) => {
                // The ring is as far ahead as it is allowed to be. Sleeping
                // rather than spinning, because this thread competes with the
                // audio callback for a core.
                std::thread::sleep(Duration::from_millis(5));
            }
            Ok(Pumped::Advanced(_)) => {
                // A queued track took over with no gap. Nothing is ending, so
                // nothing is draining; the boundary the ring carries is what
                // will tell the listener, when the audio reaches it.
                draining = false;
            }
            Ok(Pumped::TrackEnded) => {
                // The decoder reaching the end of a track is not the track
                // finishing. Everything decoded is still in the ring waiting to
                // be heard - up to the whole buffer - and announcing Ended here
                // would show a stopped player while music is still coming out.
                // It is also the moment to queue the next track, which is why
                // the engine reports it at all.
                draining = true;
            }
            Ok(Pumped::Idle) => {
                if draining && engine.queued_frames() == 0 {
                    draining = false;
                    observable
                        .state
                        .store(State::Ended.code(), Ordering::Relaxed);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(error) => {
                // A decode failure stops this track but not the player: the
                // next command must still be heard, and a shell needs to be
                // able to say what went wrong.
                draining = false;
                observable
                    .failure_kind
                    .store(FailureKind::of(&error).code(), Ordering::Relaxed);
                observable.failed.store(true, Ordering::Relaxed);
                observable
                    .state
                    .store(State::Ended.code(), Ordering::Relaxed);
                engine.stop();
            }
        }
    }
}

fn apply(
    engine: &mut Engine,
    observable: &Observable,
    sink: Option<&crate::sink::Sink>,
    command: Command,
) {
    match command {
        Command::PlayNow {
            source,
            extension,
            track,
            gain_db,
        } => {
            observable.failed.store(false, Ordering::Relaxed);
            observable.failure_kind.store(0, Ordering::Relaxed);
            match AudioDecoder::open(SourceBox(source), extension.as_deref()) {
                Ok(decoder) => {
                    observable
                        .sample_rate
                        .store(decoder.spec().sample_rate as u64, Ordering::Relaxed);
                    engine.play_now(decoder, track, gain_db);
                    observable.frames_played.store(0, Ordering::Relaxed);
                    observable.current_track.store(track, Ordering::Relaxed);
                    observable
                        .state
                        .store(State::Playing.code(), Ordering::Relaxed);
                    if let Some(sink) = sink {
                        let _ = sink.resume();
                    }
                }
                Err(error) => fail(observable, error),
            }
        }
        Command::PlayNext {
            source,
            extension,
            track,
            gain_db,
        } => match AudioDecoder::open(SourceBox(source), extension.as_deref()) {
            Ok(decoder) => {
                engine.play_next(decoder, track, gain_db);
                observable
                    .state
                    .store(State::Playing.code(), Ordering::Relaxed);
            }
            Err(error) => fail(observable, error),
        },
        Command::Pause => {
            if let Some(sink) = sink {
                let _ = sink.pause();
            }
            observable
                .state
                .store(State::Paused.code(), Ordering::Relaxed);
        }
        Command::Resume => {
            if let Some(sink) = sink {
                let _ = sink.resume();
            }
            observable
                .state
                .store(State::Playing.code(), Ordering::Relaxed);
        }
        Command::Stop => {
            engine.stop();
            if let Some(sink) = sink {
                let _ = sink.pause();
            }
            observable.frames_played.store(0, Ordering::Relaxed);
            observable
                .state
                .store(State::Idle.code(), Ordering::Relaxed);
        }
        Command::Seek(seconds) => {
            if let Ok(landed) = engine.seek(seconds) {
                observable.frames_played.store(landed, Ordering::Relaxed);
            }
        }
        Command::SetEqualizer(profile, enabled) => engine.set_equalizer(&profile, enabled),
        Command::SetReplayGain(settings) => engine.set_replay_gain(settings),
        Command::SetVolume(level) => engine.set_volume(level),
        Command::Shutdown => {}
    }
}

fn fail(observable: &Observable, error: DecodeError) {
    observable
        .failure_kind
        .store(FailureKind::of(&error).code(), Ordering::Relaxed);
    observable.failed.store(true, Ordering::Relaxed);
    observable
        .state
        .store(State::Ended.code(), Ordering::Relaxed);
}

/// Where finished audio goes.
enum Output {
    /// A real device, consuming from the ring on its own thread.
    Device(crate::sink::Sink),
    /// No usable device. Consumes at the rate a device would have, so the
    /// player still advances, still ends tracks, and still reports position -
    /// it simply makes no noise.
    Silent {
        consumer: Consumer,
        started: std::time::Instant,
        consumed: u64,
        scratch: Vec<f32>,
    },
}

impl Output {
    fn device(&self) -> Option<&crate::sink::Sink> {
        match self {
            Self::Device(sink) => Some(sink),
            Self::Silent { .. } => None,
        }
    }

    /// Consume whatever a device would have consumed by now, reporting what
    /// was actually heard.
    ///
    /// A real device does this itself on its own callback; this is only for the
    /// silent case, where nothing else would ever read the ring.
    fn drain(&mut self, sample_rate: u32, channels: u16, clock: &Observable) {
        let Self::Silent {
            consumer,
            started,
            consumed,
            scratch,
        } = self
        else {
            return;
        };

        let elapsed = started.elapsed().as_secs_f64();
        let due = (elapsed * sample_rate as f64) as u64;
        let mut owed = due.saturating_sub(*consumed) as usize;

        while owed > 0 {
            let block = owed.min(scratch.len() / channels as usize);
            let outcome = consumer.read(&mut scratch[..block * channels as usize]);
            clock.observe(outcome);
            if outcome.frames == 0 {
                // Nothing queued. Catching up later would consume a burst the
                // moment audio arrives, so the clock moves on instead.
                *consumed = due;
                return;
            }
            *consumed += outcome.frames as u64;
            owed -= outcome.frames;
        }
    }

    /// Treat now as the start, after a command that changed what is queued.
    fn restart_clock(&mut self) {
        if let Self::Silent {
            started, consumed, ..
        } = self
        {
            *started = std::time::Instant::now();
            *consumed = 0;
        }
    }
}

/// Lets a boxed `Source` satisfy the decoder's `Read + Seek` bounds.
struct SourceBox(Box<dyn Source>);

impl Read for SourceBox {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0.read(buf)
    }
}

impl Seek for SourceBox {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        self.0.seek(pos)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn wav(sample_rate: u32, samples: &[i16]) -> Vec<u8> {
        let data_bytes = (samples.len() * 2) as u32;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_bytes).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_bytes.to_le_bytes());
        for sample in samples {
            out.extend_from_slice(&sample.to_le_bytes());
        }
        out
    }

    fn source(samples: &[i16]) -> Box<dyn Source> {
        Box::new(Cursor::new(wav(8_000, samples)))
    }

    /// Wait for a condition the decode thread produces, so the tests do not
    /// depend on how fast this machine happens to be.
    fn eventually(mut check: impl FnMut() -> bool) -> bool {
        for _ in 0..400 {
            if check() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        false
    }

    #[test]
    fn a_new_player_is_idle() {
        let player = Player::new(8_000, 1, 4096).expect("should start");
        assert_eq!(player.state(), State::Idle);
        assert_eq!(player.position_seconds(), 0.0);
    }

    #[test]
    fn playing_a_track_reports_playing_and_names_it() {
        let player = Player::new(8_000, 1, 8192).expect("should start");
        player.play_now(source(&[8_000; 4_000]), Some("wav".into()), 42, None);

        assert!(
            eventually(|| player.state() == State::Playing),
            "never started playing"
        );
        assert_eq!(player.current_track(), 42);
        assert!(!player.has_failed());
    }

    /// A source that is not audio must not take the player down or leave it
    /// looking like it is playing something.
    #[test]
    fn an_undecodable_source_is_reported_rather_than_silently_ignored() {
        let player = Player::new(8_000, 1, 4096).expect("should start");
        player.play_now(Box::new(Cursor::new(vec![0u8; 64])), None, 7, None);

        assert!(
            eventually(|| player.has_failed()),
            "a source that is not audio should be reported"
        );
        assert_ne!(player.state(), State::Playing);
    }

    #[test]
    fn stopping_returns_to_idle_and_resets_the_position() {
        let player = Player::new(8_000, 1, 8192).expect("should start");
        player.play_now(source(&[8_000; 4_000]), Some("wav".into()), 1, None);
        assert!(eventually(|| player.state() == State::Playing));

        player.stop();
        assert!(
            eventually(|| player.state() == State::Idle),
            "stop should return to idle"
        );
        assert_eq!(player.position_seconds(), 0.0);
    }

    #[test]
    fn a_short_track_reaches_its_end() {
        let player = Player::new(8_000, 1, 8192).expect("should start");
        player.play_now(source(&[4_000; 200]), Some("wav".into()), 3, None);

        assert!(
            eventually(|| player.state() == State::Ended),
            "a 200 frame track should end"
        );
    }

    /// The player must survive its own controls being used in any order, since
    /// a person mashing a remote produces exactly that.
    #[test]
    fn commands_in_a_nonsensical_order_do_not_break_it() {
        let player = Player::new(8_000, 1, 8192).expect("should start");
        player.pause();
        player.seek(10.0);
        player.resume();
        player.stop();
        player.play_now(source(&[8_000; 2_000]), Some("wav".into()), 9, None);
        player.pause();
        player.resume();

        assert!(
            eventually(|| player.current_track() == 9),
            "the player should have survived and played the track"
        );
    }

    /// Every test in this module runs without a device: they use 8 kHz, and
    /// ordinary output devices offer 44.1 and 48 kHz only, so the sink refuses
    /// rather than shift the pitch. That makes the silent output the path under
    /// test here, which is worth stating outright - it was written because the
    /// alternative was a player that hangs. With nothing consuming the ring the
    /// decoder fills it, stalls, and the track never ends.
    ///
    /// So: position must advance on its own, at roughly real time, with no
    /// device present at all.
    #[test]
    fn position_advances_even_with_no_usable_device() {
        let player = Player::new(8_000, 1, 8192).expect("should start");
        player.play_now(source(&[8_000; 16_000]), Some("wav".into()), 1, None);

        assert!(
            eventually(|| player.position_seconds() > 0.05),
            "position never moved; nothing is consuming the ring"
        );

        let early = player.position_seconds();
        std::thread::sleep(Duration::from_millis(200));
        let later = player.position_seconds();

        assert!(later > early, "position stalled at {early}");
        assert!(
            later < early + 1.0,
            "position ran far ahead of real time: {early} to {later}"
        );
    }

    /// Dropping must not hang. The decode thread is joined rather than
    /// detached, so a shutdown that is not noticed would deadlock here.
    #[test]
    fn dropping_a_playing_player_shuts_the_thread_down() {
        let player = Player::new(8_000, 1, 8192).expect("should start");
        player.play_now(source(&[8_000; 40_000]), Some("wav".into()), 1, None);
        assert!(eventually(|| player.state() == State::Playing));

        drop(player); // would hang if shutdown were missed
    }
}

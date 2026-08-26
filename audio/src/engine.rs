//! Pulling decoded audio through the effects and into the ring.
//!
//! This is the part that runs on the decode thread. It owns the decoder, the
//! equaliser and the ReplayGain settings, and its whole job is to keep the ring
//! from running dry without ever getting so far ahead that a skip has to throw
//! away seconds of work.
//!
//! # Order of operations, and why it is not arbitrary
//!
//! ReplayGain is applied before the equaliser, not after. ReplayGain answers
//! "how loud was this recording mastered", which is a property of the file; the
//! equaliser answers "how does this listener want music to sound", which is a
//! property of the person. Applying the listener's boost first and then
//! normalising would let a bass-heavy preset change how loud a track ends up,
//! so two tracks with identical ReplayGain tags would no longer match. Doing it
//! in this order means the normalisation means the same thing whatever the
//! equaliser is set to.
//!
//! # Why the pump is bounded work rather than a loop until full
//!
//! [`Engine::pump`] does a fixed, small amount of work and returns. It would be
//! simpler to loop until the ring is full, but then a seek issued during that
//! loop waits for it to finish, and the wait grows with the buffer. Returning
//! often means the thread driving this can notice a command between packets,
//! and the cost is a few extra function calls per second.

use crate::decode::{AudioDecoder, DecodeError, StreamSpec};
use crate::resample::Resampler;
use crate::ring::{Consumer, Producer};
use crate::{Equalizer, EqualizerProfile, ReplayGainSettings};

/// A track waiting to start the instant the current one runs out.
struct Queued {
    decoder: AudioDecoder,
    track: u64,
    gain_db: Option<f64>,
}

/// What one call to [`Engine::pump`] managed to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pumped {
    /// Frames were decoded and queued.
    Wrote(usize),
    /// The ring has no room. Nothing was decoded, and nothing was lost.
    Full,
    /// The current track decoded to its end and a queued one took over with
    /// nothing between them. Carries the track that just started.
    ///
    /// Distinct from [`Pumped::TrackEnded`] because a caller needs to know it
    /// should queue another, and because "one track ended" and "the music
    /// stopped" are not the same thing.
    Advanced(u64),
    /// The current track decoded to its end and nothing was queued behind it.
    TrackEnded,
    /// There is no track loaded.
    Idle,
}

/// The shell's volume control: a linear gain applied last in the chain.
///
/// A change ramps to the new level across one buffer rather than jumping, so
/// the discontinuity that a hard multiply would put in the signal - heard as a
/// click - never occurs. The ramp is short (one packet, a few milliseconds),
/// which is enough to remove the click without the level audibly sliding.
#[derive(Debug, Clone, Copy)]
struct Volume {
    current: f32,
    target: f32,
}

impl Volume {
    fn new() -> Self {
        Self {
            current: 1.0,
            target: 1.0,
        }
    }

    /// Aim for `level`, clamped to the sensible `0.0..=1.0` range. The move is
    /// realised by [`Volume::process`] on the next buffer.
    fn set(&mut self, level: f32) {
        self.target = level.clamp(0.0, 1.0);
    }

    /// Scale `samples` in place, ramping from the current level to the target
    /// across the buffer so no single buffer contains a step.
    fn process(&mut self, samples: &mut [f32], channels: usize) {
        if self.current == self.target {
            // Unity needs no work, and skipping it keeps a full-volume signal
            // bit-for-bit what the equaliser produced.
            if self.current != 1.0 {
                for s in samples.iter_mut() {
                    *s *= self.current;
                }
            }
            return;
        }

        let channels = channels.max(1);
        let frames = samples.len() / channels;
        if frames == 0 {
            for s in samples.iter_mut() {
                *s *= self.target;
            }
            self.current = self.target;
            return;
        }

        // Every sample in a frame gets the same gain, so the ramp advances once
        // per frame rather than per sample and the channels stay in step.
        let step = (self.target - self.current) / frames as f32;
        let mut gain = self.current;
        for frame in samples.chunks_mut(channels) {
            for s in frame.iter_mut() {
                *s *= gain;
            }
            gain += step;
        }
        self.current = self.target;
    }
}

/// Decode, process, and fill the ring.
pub struct Engine {
    decoder: Option<AudioDecoder>,
    /// The track to start the moment the current decoder runs out.
    ///
    /// This exists because gapless means queueing *ahead*, while a track is
    /// still playing. Without it, `play_next` had to replace the live decoder,
    /// which truncated whatever was playing - so the only safe moment to call
    /// it was after the current track had already finished decoding, by which
    /// point queueing ahead is exactly what has not happened.
    next: Option<Queued>,
    equalizer: Equalizer,
    /// The settings the equaliser realises.
    ///
    /// Kept separately because the profile is what the user chose and the
    /// `Equalizer` is one realisation of it at one sample rate. Rebuilding for
    /// a track at a different rate needs the choice, not the realisation.
    profile: EqualizerProfile,
    equalizer_enabled: bool,
    replay_gain: ReplayGainSettings,
    /// The shell's own volume control, applied after everything else.
    ///
    /// Distinct from ReplayGain (which describes the recording) and the
    /// equaliser (which describes tone): this is the level the listener sets
    /// moment to moment, so it belongs last in the chain and persists across
    /// tracks rather than being reset with the decoder.
    volume: Volume,
    ring: Producer,
    channels: usize,
    /// The identifier reported at the boundary when this track starts playing.
    pending_track: Option<u64>,
    /// The rate the output device actually runs at.
    ///
    /// Everything after the decoder works at this rate, which is why the
    /// equaliser is built once here rather than rebuilt per track: its
    /// coefficients depend on the rate, and the rate no longer changes.
    device_rate: u32,
    /// Present only when the current track's rate differs from the device's.
    ///
    /// A device runs at the rate it runs at - 48 kHz on a phone, often 44.1 on
    /// desktop hardware - and a file is whatever it was mastered at. Without
    /// this the choice is shifting the pitch or refusing to play, and refusing
    /// to play is what produced a moving progress bar with no sound.
    resampler: Option<Resampler>,
    /// Scratch for resampled frames, reused so a packet does not allocate.
    resampled: Vec<f32>,
    /// Frames left over from a packet the ring could not take in full.
    ///
    /// Without this, a packet that half fits would be either truncated - losing
    /// audio silently - or refused and decoded again, which for a codec with
    /// inter-packet state is not a repeatable operation.
    carry: Vec<f32>,
}

impl Engine {
    /// Build an engine writing into `ring`.
    pub fn new(ring: Producer, channels: usize) -> Self {
        Self::with_device_rate(ring, channels, 44_100)
    }

    /// Build an engine that feeds a device running at `device_rate`.
    pub fn with_device_rate(ring: Producer, channels: usize, device_rate: u32) -> Self {
        Self {
            decoder: None,
            next: None,
            equalizer: Equalizer::new(device_rate as f64, channels),
            device_rate,
            resampler: None,
            resampled: Vec::new(),
            profile: EqualizerProfile::flat(),
            equalizer_enabled: false,
            replay_gain: ReplayGainSettings::default(),
            volume: Volume::new(),
            ring,
            channels,
            pending_track: None,
            carry: Vec::new(),
        }
    }

    /// Begin a track, keeping whatever is already queued.
    ///
    /// Nothing is flushed, which is the point: the audio already in the ring
    /// plays out and this track's first sample follows the previous track's
    /// last with nothing between them. A boundary is recorded at the position
    /// the new audio will land, so the change is reported when it is heard
    /// rather than now.
    pub fn play_next(&mut self, decoder: AudioDecoder, track: u64, gain_db: Option<f64>) {
        if self.decoder.is_some() {
            // Something is playing, so this waits behind it. Replacing the live
            // decoder here is what the previous version did, and it silently
            // truncated the current track - which made queueing ahead, the
            // entire point of the method, the one thing it could not do.
            self.next = Some(Queued {
                decoder,
                track,
                gain_db,
            });
            return;
        }
        self.start(decoder, track, gain_db);
    }

    /// True when nothing is waiting behind the current track.
    ///
    /// A caller uses this to decide whether to fetch another, rather than
    /// queueing the same track repeatedly.
    pub fn wants_next(&self) -> bool {
        self.next.is_none()
    }

    fn start(&mut self, decoder: AudioDecoder, track: u64, gain_db: Option<f64>) {
        let spec = decoder.spec();
        self.configure_for(spec);
        self.replay_gain.track_gain_db = gain_db;
        self.decoder = Some(decoder);
        self.pending_track = Some(track);
        self.carry.clear();
    }

    /// Begin a track now, discarding anything queued.
    ///
    /// This is a skip or a seek. Audio already handed to the speaker cannot be
    /// recalled, but nothing behind it should still be heard.
    pub fn play_now(&mut self, decoder: AudioDecoder, track: u64, gain_db: Option<f64>) {
        // Whatever was queued was queued behind audio that is being discarded,
        // so it is no longer what comes next.
        self.next = None;
        self.ring.reset();
        // Filters hold the tail of the audio that went through them. Carried
        // into unrelated audio that is a transient at the join, so the filter
        // state has to go when the audio it describes does.
        self.equalizer.reset();
        // Start, rather than play_next. play_next deliberately queues behind a
        // live decoder instead of replacing it - that is what makes queueing
        // ahead work - so delegating here meant "play now" became "play after"
        // for every track but the first. The shell picks a song, the ring is
        // emptied and refilled from the SAME decoder, and the chosen track waits
        // in `next` forever while the original plays on.
        self.start(decoder, track, gain_db);
    }

    /// Stop, discarding everything queued.
    pub fn stop(&mut self) {
        self.ring.reset();
        self.equalizer.reset();
        self.decoder = None;
        self.next = None;
        self.pending_track = None;
        self.carry.clear();
    }

    /// Replace the equaliser settings, keeping playback going.
    ///
    /// Filter state is deliberately *not* reset. The coefficients change but
    /// the audio does not jump, so moving a slider mid-track is a change in
    /// tone rather than a click.
    pub fn set_equalizer(&mut self, profile: &EqualizerProfile, enabled: bool) {
        let sample_rate = self
            .decoder
            .as_ref()
            .map(|d| d.spec().sample_rate as f64)
            .unwrap_or(44_100.0);
        self.profile = profile.clone();
        self.equalizer_enabled = enabled;
        self.equalizer = Equalizer::from_profile(sample_rate, self.channels, profile, enabled);
    }

    /// Replace the ReplayGain settings.
    pub fn set_replay_gain(&mut self, settings: ReplayGainSettings) {
        // The per-track gain belongs to the track, not to the settings, so it
        // survives a settings change that arrives mid-track.
        let track_gain = self.replay_gain.track_gain_db;
        self.replay_gain = settings;
        self.replay_gain.track_gain_db = track_gain;
    }

    /// Set the shell's volume, `0.0` silent to `1.0` unity.
    ///
    /// The change is ramped by [`Volume`] across the next buffer rather than
    /// applied as a step, so moving the slider is a fade, not a click.
    pub fn set_volume(&mut self, level: f32) {
        self.volume.set(level);
    }

    /// Seek the current track, discarding queued audio from the old position.
    pub fn seek(&mut self, seconds: f64) -> Result<u64, DecodeError> {
        let Some(decoder) = self.decoder.as_mut() else {
            return Ok(0);
        };
        let landed = decoder.seek(seconds)?;
        self.ring.reset();
        self.equalizer.reset();
        if let Some(resampler) = self.resampler.as_mut() {
            // Filter history describes audio that is no longer adjacent.
            resampler.reset();
        }
        self.carry.clear();
        Ok(landed)
    }

    /// Frames decoded but not yet heard.
    ///
    /// A decoder that has reached the end of a track is not a track that has
    /// finished playing; those are separated by however much buffer was filled.
    pub fn queued_frames(&self) -> usize {
        self.ring.queued_frames() + self.carry.len() / self.channels.max(1)
    }

    /// Do one packet's worth of work.
    pub fn pump(&mut self) -> Result<Pumped, DecodeError> {
        // Anything left from last time goes first, or the stream would come out
        // of order.
        if !self.carry.is_empty() {
            let taken = self.write_frames_from_carry();
            return Ok(if taken == 0 {
                Pumped::Full
            } else {
                Pumped::Wrote(taken)
            });
        }

        if self.decoder.is_none() {
            return Ok(Pumped::Idle);
        }

        if self.ring.free_frames() == 0 {
            return Ok(Pumped::Full);
        }

        // The boundary has to be recorded before the frames it labels are
        // written, or the consumer could read past it and never report it.
        if let Some(track) = self.pending_track {
            if self.ring.mark_boundary(track) {
                self.pending_track = None;
            }
        }

        let decoder = self.decoder.as_mut().expect("checked above");
        let decoded = match decoder.next_frames()? {
            Some(frames) => frames,
            None => {
                // The decoder ran out. If something is waiting, it takes over
                // immediately and its first sample lands against the last of
                // this track with nothing between them - which is what gapless
                // is. No ring reset, no equaliser reset: both would put a seam
                // exactly where there must not be one.
                if let Some(queued) = self.next.take() {
                    let track = queued.track;
                    self.start(queued.decoder, track, queued.gain_db);
                    return Ok(Pumped::Advanced(track));
                }
                self.decoder = None;
                return Ok(Pumped::TrackEnded);
            }
        };

        self.carry.clear();
        if let Some(resampler) = self.resampler.as_mut() {
            // Resample before anything else, so every stage after this - gain,
            // tone, volume - works at one rate that never changes.
            let frames = decoded.len() / self.channels.max(1);
            self.resampled.resize(
                resampler.output_estimate(frames) * self.channels.max(1),
                0.0,
            );
            let produced = resampler.process(decoded, &mut self.resampled);
            self.carry
                .extend_from_slice(&self.resampled[..produced * self.channels.max(1)]);
            if self.carry.is_empty() {
                // The filter has not produced anything yet, which happens only
                // while it fills. Not the end of anything.
                return Ok(Pumped::Wrote(0));
            }
        } else {
            self.carry.extend_from_slice(decoded);
        }

        // ReplayGain first, then the equaliser: normalisation describes the
        // recording, tone describes the listener, and doing it the other way
        // round would let a bass-heavy preset change how loud a track lands.
        crate::apply_replay_gain(&mut self.carry, self.replay_gain);
        self.equalizer.process(&mut self.carry);
        // Volume last, so the listener's level rides on top of the final tone
        // and normalisation rather than being reshaped by them.
        self.volume.process(&mut self.carry, self.channels);

        let taken = self.write_frames_from_carry();
        Ok(if taken == 0 {
            Pumped::Full
        } else {
            Pumped::Wrote(taken)
        })
    }

    /// Push as much of `carry` into the ring as fits, keeping the remainder.
    fn write_frames_from_carry(&mut self) -> usize {
        let taken = self.ring.write(&self.carry);
        if taken > 0 {
            self.carry.drain(..taken * self.channels);
        }
        taken
    }

    /// Rebuild the equaliser when a track's sample rate differs from the last.
    ///
    /// Biquad coefficients are computed against a sample rate. Reusing them
    /// across a rate change moves every centre frequency, so a 48 kHz track
    /// following a 44.1 kHz one would be filtered at the wrong frequencies -
    /// audible, and easy to mistake for a bad master.
    /// Set up for a track, resampling it to the device rate if it differs.
    ///
    /// The equaliser is deliberately NOT rebuilt per track any more. Its
    /// coefficients are computed against a sample rate, and everything past the
    /// resampler is at the device's rate, so rebuilding would only ever produce
    /// the same filter - while the old per-track rebuild moved every centre
    /// frequency whenever a 48 kHz track followed a 44.1 kHz one.
    fn configure_for(&mut self, spec: StreamSpec) {
        let channels_changed = spec.channels != self.channels;
        self.channels = spec.channels;

        self.resampler = Resampler::new(spec.sample_rate, self.device_rate, spec.channels);
        self.resampled.clear();

        if channels_changed {
            self.equalizer = Equalizer::from_profile(
                self.device_rate as f64,
                spec.channels,
                &self.profile,
                self.equalizer_enabled,
            );
        }
    }
}

/// Drive an engine until the ring is full or the track ends.
///
/// A convenience for tests and for callers that have nothing else to do; a real
/// player calls [`Engine::pump`] itself so it can notice commands in between.
pub fn fill(engine: &mut Engine) -> Result<Pumped, DecodeError> {
    loop {
        match engine.pump()? {
            // Advancing is not stopping: a queued track taking over means there
            // is more to decode, so filling continues through the join.
            Pumped::Wrote(_) | Pumped::Advanced(_) => continue,
            other => return Ok(other),
        }
    }
}

/// Read everything currently queued, for tests.
#[doc(hidden)]
pub fn drain(consumer: &mut Consumer, channels: usize) -> Vec<f32> {
    let mut all = Vec::new();
    let mut block = vec![0.0; 256 * channels];
    loop {
        let outcome = consumer.read(&mut block);
        if outcome.frames == 0 {
            return all;
        }
        all.extend_from_slice(&block[..outcome.frames * channels]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ring::ring;
    use std::io::Cursor;

    fn wav(channels: u16, sample_rate: u32, samples: &[i16]) -> Vec<u8> {
        let data_bytes = (samples.len() * 2) as u32;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_bytes).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        let block_align = channels * 2;
        out.extend_from_slice(&(sample_rate * block_align as u32).to_le_bytes());
        out.extend_from_slice(&block_align.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_bytes.to_le_bytes());
        for sample in samples {
            out.extend_from_slice(&sample.to_le_bytes());
        }
        out
    }

    /// The fixtures are 8 kHz, so the engines in these tests are built for an
    /// 8 kHz device. Otherwise every one of them would be resampling to 44.1
    /// and asserting frame counts that belong to a different test - resampling
    /// has its own, in `resample`.
    fn decoder(samples: &[i16]) -> AudioDecoder {
        AudioDecoder::open(Cursor::new(wav(1, 8_000, samples)), Some("wav")).unwrap()
    }

    #[test]
    fn audio_reaches_the_ring() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);
        engine.play_next(decoder(&[16_384; 100]), 1, None);

        fill(&mut engine).unwrap();
        let out = drain(&mut rx, 1);

        assert_eq!(out.len(), 100);
        assert!((out[0] - 0.5).abs() < 0.01, "expected ~0.5, got {}", out[0]);
    }

    #[test]
    fn an_idle_engine_says_so_rather_than_producing_silence() {
        let (tx, mut rx) = ring(64, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);

        assert_eq!(engine.pump().unwrap(), Pumped::Idle);
        assert!(drain(&mut rx, 1).is_empty());
    }

    /// Choosing a song while one is already playing must replace it.
    ///
    /// `play_now` used to delegate to `play_next`, which deliberately queues
    /// behind a live decoder rather than replacing it. The ring was emptied and
    /// then refilled from the SAME decoder, so the shell showed the new track
    /// and the speakers carried on with the old one - for every track after the
    /// first, forever.
    ///
    /// The first track here is longer than the ring on purpose: `fill` stops at
    /// a full ring with the decoder still live, which is the state the bug
    /// needed. A short first track ends, clears itself, and hides it.
    #[test]
    fn play_now_replaces_what_is_already_playing() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);

        engine.play_next(decoder(&[16_384; 10_000]), 1, None);
        fill(&mut engine).unwrap();
        let first = drain(&mut rx, 1);
        assert!((first[0] - 0.5).abs() < 0.01, "fixture wrong: {}", first[0]);

        engine.play_now(decoder(&[8_192; 100]), 2, None);
        fill(&mut engine).unwrap();
        let out = drain(&mut rx, 1);

        assert!(!out.is_empty(), "play_now produced no audio at all");
        assert!(
            (out[0] - 0.25).abs() < 0.01,
            "expected the chosen track (~0.25), heard ~{} - play_now queued \
             behind the live decoder instead of replacing it",
            out[0]
        );
    }

    #[test]
    fn a_track_reports_its_end_exactly_once() {
        let (tx, _rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);
        engine.play_next(decoder(&[1_000; 40]), 7, None);

        assert_eq!(fill(&mut engine).unwrap(), Pumped::TrackEnded);
        assert_eq!(engine.pump().unwrap(), Pumped::Idle, "ended twice");
    }

    /// The join is the whole point. Two tracks queued back to back must produce
    /// one continuous stream with no silence inserted where they meet.
    #[test]
    fn two_tracks_meet_with_nothing_between_them() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);

        engine.play_next(decoder(&[16_384; 50]), 1, None);
        assert_eq!(fill(&mut engine).unwrap(), Pumped::TrackEnded);
        engine.play_next(decoder(&[-16_384; 50]), 2, None);
        assert_eq!(fill(&mut engine).unwrap(), Pumped::TrackEnded);

        let out = drain(&mut rx, 1);
        assert_eq!(out.len(), 100, "expected both tracks queued");
        for (index, sample) in out.iter().enumerate() {
            assert!(
                sample.abs() > 0.4,
                "frame {index} is near silence at the join: {sample}"
            );
        }
    }

    /// The test that was missing, and whose absence hid a real bug.
    ///
    /// Every other gapless test queued the second track only *after* the first
    /// had finished decoding, which is the one moment queueing ahead has
    /// already failed to happen. Queued while the first is still playing,
    /// `play_next` used to replace the live decoder and silently truncate it -
    /// so the method whose entire purpose is to queue ahead was the one thing
    /// that could not.
    #[test]
    fn queueing_while_a_track_is_playing_does_not_truncate_it() {
        let (tx, mut rx) = ring(8192, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);

        // Long enough that one pump decodes a small fraction of it. A short
        // track hides this bug completely: a single packet decodes the whole
        // thing, so replacing the decoder afterwards loses nothing and the
        // test passes against broken code. The first version of this test did
        // exactly that and proved nothing.
        const FIRST: usize = 40_000;
        const SECOND: usize = 5_000;

        engine.play_next(decoder(&[16_384; FIRST]), 1, None);
        engine.pump().unwrap();
        // Still playing, and most of it is not decoded yet.
        engine.play_next(decoder(&[-16_384; SECOND]), 2, None);

        let mut collected = Vec::new();
        for _ in 0..100_000 {
            let state = engine.pump().unwrap();
            collected.extend_from_slice(&drain(&mut rx, 1));
            if matches!(state, Pumped::TrackEnded | Pumped::Idle) {
                collected.extend_from_slice(&drain(&mut rx, 1));
                break;
            }
        }

        assert_eq!(
            collected.len(),
            FIRST + SECOND,
            "a short count means queueing truncated the track that was playing"
        );
        assert!(
            collected[..FIRST].iter().all(|s| *s > 0.4),
            "first track intact"
        );
        assert!(
            collected[FIRST..].iter().all(|s| *s < -0.4),
            "second track followed it"
        );
    }

    #[test]
    fn advancing_reports_the_track_that_took_over() {
        let (tx, _rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);

        engine.play_next(decoder(&[8_000; 20]), 11, None);
        engine.pump().unwrap();
        engine.play_next(decoder(&[8_000; 20]), 22, None);

        let mut advanced = None;
        for _ in 0..50 {
            if let Pumped::Advanced(track) = engine.pump().unwrap() {
                advanced = Some(track);
                break;
            }
        }
        assert_eq!(advanced, Some(22));
    }

    /// A caller needs to know whether to fetch another track, rather than
    /// queueing the same one repeatedly.
    #[test]
    fn it_says_whether_something_is_already_waiting() {
        let (tx, _rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);

        assert!(engine.wants_next(), "nothing playing, nothing queued");
        engine.play_next(decoder(&[8_000; 40]), 1, None);
        engine.pump().unwrap();
        assert!(engine.wants_next(), "playing, but nothing behind it");
        engine.play_next(decoder(&[8_000; 40]), 2, None);
        assert!(!engine.wants_next(), "something is waiting now");
    }

    /// Playing something now discards what was queued behind the audio being
    /// thrown away, because it is no longer what comes next.
    #[test]
    fn playing_now_also_drops_whatever_was_queued_behind_it() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);

        engine.play_next(decoder(&[16_384; 80]), 1, None);
        engine.pump().unwrap();
        engine.play_next(decoder(&[16_384; 80]), 2, None);
        engine.play_now(decoder(&[-8_192; 10]), 3, None);

        let _ = fill(&mut engine);
        let out = drain(&mut rx, 1);
        assert_eq!(out.len(), 10, "only the new track should remain");
        assert!(engine.wants_next(), "the stale queue should be gone");
    }

    /// The boundary must be reported when the audio reaches it, and must
    /// describe the track that starts there.
    #[test]
    fn the_boundary_names_the_track_that_starts_at_it() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);

        engine.play_next(decoder(&[8_000; 20]), 111, None);
        fill(&mut engine).unwrap();
        engine.play_next(decoder(&[8_000; 20]), 222, None);
        fill(&mut engine).unwrap();

        let mut first = [0.0; 20];
        let outcome = rx.read(&mut first);
        assert_eq!(outcome.boundary.map(|b| b.track), Some(111));

        let mut second = [0.0; 20];
        let outcome = rx.read(&mut second);
        assert_eq!(
            outcome.boundary.map(|b| b.track),
            Some(222),
            "the second track's boundary should arrive with its audio"
        );
    }

    #[test]
    fn playing_now_discards_what_was_queued() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);

        engine.play_next(decoder(&[16_384; 200]), 1, None);
        fill(&mut engine).unwrap();

        engine.play_now(decoder(&[-8_192; 10]), 2, None);
        fill(&mut engine).unwrap();

        let out = drain(&mut rx, 1);
        assert_eq!(out.len(), 10, "the queued track should have been dropped");
        assert!(out[0] < 0.0, "what remains should be the new track");
    }

    /// ReplayGain has to change the samples, and the engine has to apply it -
    /// a pipeline that quietly ignores the setting looks identical to one that
    /// applies it to a track tagged 0 dB.
    #[test]
    fn replay_gain_is_actually_applied() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);
        engine.set_replay_gain(ReplayGainSettings::new(crate::ReplayGainMode::Track));
        engine.play_next(decoder(&[8_192; 20]), 1, Some(-6.0));

        fill(&mut engine).unwrap();
        let attenuated = drain(&mut rx, 1);

        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);
        engine.set_replay_gain(ReplayGainSettings::new(crate::ReplayGainMode::Track));
        engine.play_next(decoder(&[8_192; 20]), 1, None);
        fill(&mut engine).unwrap();
        let plain = drain(&mut rx, 1);

        assert!(
            attenuated[0].abs() < plain[0].abs(),
            "a -6 dB tag should be quieter: {} vs {}",
            attenuated[0],
            plain[0]
        );
    }

    /// A packet larger than the space left must not be truncated or decoded
    /// twice. Codecs carry state between packets, so decoding one again is not
    /// a repeatable operation.
    #[test]
    fn a_packet_that_does_not_fit_is_carried_rather_than_lost() {
        let samples: Vec<i16> = (0..500).map(|v| ((v % 100) * 300) as i16).collect();
        let (tx, mut rx) = ring(64, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);
        engine.play_next(decoder(&samples), 1, None);

        // Fill, drain, refill until the track is done, which forces the carry
        // path repeatedly because the ring is far smaller than the track.
        let mut collected = Vec::new();
        loop {
            let state = fill(&mut engine).unwrap();
            collected.extend_from_slice(&drain(&mut rx, 1));
            if state == Pumped::TrackEnded {
                collected.extend_from_slice(&drain(&mut rx, 1));
                break;
            }
        }

        assert_eq!(collected.len(), 500, "frames went missing across the carry");
        for (index, sample) in collected.iter().enumerate() {
            let expected = ((index % 100) * 300) as f32 / 32_768.0;
            assert!(
                (sample - expected).abs() < 0.01,
                "frame {index} came out as {sample}, expected {expected}"
            );
        }
    }

    /// The tag travels with the track whether or not it is being used, and the
    /// mode decides. An engine that applied the tag regardless would make the
    /// Off setting a lie; one that dropped the tag when Off would need the
    /// track re-decoded to turn normalisation back on.
    #[test]
    fn the_off_mode_ignores_a_tag_rather_than_discarding_it() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);
        engine.play_next(decoder(&[8_192; 20]), 1, Some(-6.0));
        fill(&mut engine).unwrap();
        let untouched = drain(&mut rx, 1);

        assert!(
            (untouched[0] - 0.25).abs() < 0.01,
            "Off should leave the samples alone, got {}",
            untouched[0]
        );
    }

    #[test]
    fn stopping_leaves_the_engine_idle_and_the_ring_empty() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);
        engine.play_next(decoder(&[16_384; 100]), 1, None);
        fill(&mut engine).unwrap();

        engine.stop();

        assert_eq!(engine.pump().unwrap(), Pumped::Idle);
        assert!(drain(&mut rx, 1).is_empty());
    }

    #[test]
    fn volume_scales_the_signal_the_listener_hears() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);
        // Set volume before the track so the whole buffer is at the new level
        // rather than ramping up from unity.
        engine.set_volume(0.5);
        engine.play_next(decoder(&[16_384; 100]), 1, None);

        fill(&mut engine).unwrap();
        let out = drain(&mut rx, 1);

        assert_eq!(out.len(), 100);
        // 16_384/32_768 = 0.5 at unity; half volume halves it again. The gain
        // ramps from unity across the first buffer, so the settled tail is the
        // level to check, not the first frame.
        assert!(
            (out[out.len() - 1] - 0.25).abs() < 0.01,
            "expected ~0.25 at half volume, got {}",
            out[out.len() - 1]
        );
    }

    #[test]
    fn a_volume_change_ramps_rather_than_stepping() {
        // A hard cut would put a step in the signal - a click. The ramp means
        // the first frame after a change is still near the old level and the
        // last is at the new one, with everything in between monotonic.
        let mut volume = Volume::new();
        volume.set(0.0);
        let mut buffer = vec![1.0f32; 8];
        volume.process(&mut buffer, 1);

        assert!(
            buffer[0] > buffer[buffer.len() - 1],
            "the ramp should descend, got {buffer:?}"
        );
        assert!(
            buffer[0] > 0.9,
            "the first frame should still be near the old level, got {}",
            buffer[0]
        );
        for pair in buffer.windows(2) {
            assert!(
                pair[0] >= pair[1],
                "the ramp must be monotonic, got {buffer:?}"
            );
        }
    }

    #[test]
    fn volume_persists_across_a_track_change() {
        // Volume is the listener's setting, not the track's, so starting a new
        // track must not quietly reset it to unity.
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::with_device_rate(tx, 1, 8_000);
        engine.set_volume(0.5);
        engine.play_now(decoder(&[16_384; 20]), 1, None);
        fill(&mut engine).unwrap();
        let _ = drain(&mut rx, 1);

        engine.play_now(decoder(&[16_384; 100]), 2, None);
        fill(&mut engine).unwrap();
        let out = drain(&mut rx, 1);

        assert!(
            (out[out.len() - 1] - 0.25).abs() < 0.01,
            "half volume should carry into the next track, got {}",
            out[out.len() - 1]
        );
    }
}

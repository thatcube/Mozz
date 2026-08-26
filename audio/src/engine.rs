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
use crate::ring::{Consumer, Producer};
use crate::{Equalizer, EqualizerProfile, ReplayGainSettings};

/// What one call to [`Engine::pump`] managed to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pumped {
    /// Frames were decoded and queued.
    Wrote(usize),
    /// The ring has no room. Nothing was decoded, and nothing was lost.
    Full,
    /// The current track decoded to its end.
    ///
    /// The engine keeps its position so the next track can be started without
    /// the ring draining, which is what makes the join gapless.
    TrackEnded,
    /// There is no track loaded.
    Idle,
}

/// Decode, process, and fill the ring.
pub struct Engine {
    decoder: Option<AudioDecoder>,
    equalizer: Equalizer,
    /// The settings the equaliser realises.
    ///
    /// Kept separately because the profile is what the user chose and the
    /// `Equalizer` is one realisation of it at one sample rate. Rebuilding for
    /// a track at a different rate needs the choice, not the realisation.
    profile: EqualizerProfile,
    equalizer_enabled: bool,
    replay_gain: ReplayGainSettings,
    ring: Producer,
    channels: usize,
    /// The identifier reported at the boundary when this track starts playing.
    pending_track: Option<u64>,
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
        Self {
            decoder: None,
            equalizer: Equalizer::new(44_100.0, channels),
            profile: EqualizerProfile::flat(),
            equalizer_enabled: false,
            replay_gain: ReplayGainSettings::default(),
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
        self.ring.reset();
        // Filters hold the tail of the audio that went through them. Carried
        // into unrelated audio that is a transient at the join, so the filter
        // state has to go when the audio it describes does.
        self.equalizer.reset();
        self.play_next(decoder, track, gain_db);
    }

    /// Stop, discarding everything queued.
    pub fn stop(&mut self) {
        self.ring.reset();
        self.equalizer.reset();
        self.decoder = None;
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

    /// Seek the current track, discarding queued audio from the old position.
    pub fn seek(&mut self, seconds: f64) -> Result<u64, DecodeError> {
        let Some(decoder) = self.decoder.as_mut() else {
            return Ok(0);
        };
        let landed = decoder.seek(seconds)?;
        self.ring.reset();
        self.equalizer.reset();
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
                self.decoder = None;
                return Ok(Pumped::TrackEnded);
            }
        };

        self.carry.clear();
        self.carry.extend_from_slice(decoded);

        // ReplayGain first, then the equaliser: normalisation describes the
        // recording, tone describes the listener, and doing it the other way
        // round would let a bass-heavy preset change how loud a track lands.
        crate::apply_replay_gain(&mut self.carry, self.replay_gain);
        self.equalizer.process(&mut self.carry);

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
    fn configure_for(&mut self, spec: StreamSpec) {
        self.channels = spec.channels;
        self.equalizer = Equalizer::from_profile(
            spec.sample_rate as f64,
            spec.channels,
            &self.profile,
            self.equalizer_enabled,
        );
    }
}

/// Drive an engine until the ring is full or the track ends.
///
/// A convenience for tests and for callers that have nothing else to do; a real
/// player calls [`Engine::pump`] itself so it can notice commands in between.
pub fn fill(engine: &mut Engine) -> Result<Pumped, DecodeError> {
    loop {
        match engine.pump()? {
            Pumped::Wrote(_) => continue,
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

    fn decoder(samples: &[i16]) -> AudioDecoder {
        AudioDecoder::open(Cursor::new(wav(1, 8_000, samples)), Some("wav")).unwrap()
    }

    #[test]
    fn audio_reaches_the_ring() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::new(tx, 1);
        engine.play_next(decoder(&[16_384; 100]), 1, None);

        fill(&mut engine).unwrap();
        let out = drain(&mut rx, 1);

        assert_eq!(out.len(), 100);
        assert!((out[0] - 0.5).abs() < 0.01, "expected ~0.5, got {}", out[0]);
    }

    #[test]
    fn an_idle_engine_says_so_rather_than_producing_silence() {
        let (tx, mut rx) = ring(64, 1);
        let mut engine = Engine::new(tx, 1);

        assert_eq!(engine.pump().unwrap(), Pumped::Idle);
        assert!(drain(&mut rx, 1).is_empty());
    }

    #[test]
    fn a_track_reports_its_end_exactly_once() {
        let (tx, _rx) = ring(4096, 1);
        let mut engine = Engine::new(tx, 1);
        engine.play_next(decoder(&[1_000; 40]), 7, None);

        assert_eq!(fill(&mut engine).unwrap(), Pumped::TrackEnded);
        assert_eq!(engine.pump().unwrap(), Pumped::Idle, "ended twice");
    }

    /// The join is the whole point. Two tracks queued back to back must produce
    /// one continuous stream with no silence inserted where they meet.
    #[test]
    fn two_tracks_meet_with_nothing_between_them() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::new(tx, 1);

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

    /// The boundary must be reported when the audio reaches it, and must
    /// describe the track that starts there.
    #[test]
    fn the_boundary_names_the_track_that_starts_at_it() {
        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::new(tx, 1);

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
        let mut engine = Engine::new(tx, 1);

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
        let mut engine = Engine::new(tx, 1);
        engine.set_replay_gain(ReplayGainSettings::new(crate::ReplayGainMode::Track));
        engine.play_next(decoder(&[8_192; 20]), 1, Some(-6.0));

        fill(&mut engine).unwrap();
        let attenuated = drain(&mut rx, 1);

        let (tx, mut rx) = ring(4096, 1);
        let mut engine = Engine::new(tx, 1);
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
        let mut engine = Engine::new(tx, 1);
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
        let mut engine = Engine::new(tx, 1);
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
        let mut engine = Engine::new(tx, 1);
        engine.play_next(decoder(&[16_384; 100]), 1, None);
        fill(&mut engine).unwrap();

        engine.stop();

        assert_eq!(engine.pump().unwrap(), Pumped::Idle);
        assert!(drain(&mut rx, 1).is_empty());
    }
}

//! Turning encoded audio into interleaved `f32` frames.
//!
//! # Why this is in the shared crate
//!
//! Decoding is the first place two platforms can disagree about what a file
//! sounds like. AVFoundation, Media Foundation, and whatever Android happens to
//! ship all decode the same MP3 to slightly different samples, and they differ
//! again in what they will open at all: one platform silently refuses a file
//! another plays, and the library appears to have holes that depend on which
//! device you are holding.
//!
//! Symphonia decodes the same bytes to the same samples everywhere, because it
//! is the same code everywhere. That is the whole argument. Not that a Rust
//! decoder is faster or better - that "sound may not differ between platforms"
//! is a promise nobody can keep while each platform brings its own decoder.
//!
//! # Everything becomes `f32`
//!
//! Sources arrive as `u8`, `i16`, `i24`, `i32` or float, planar or
//! interleaved. All of it is converted to interleaved `f32` here, once, so that
//! nothing downstream - equaliser, ReplayGain, the ring, the sinks - has to
//! know or care what the file was. A pipeline that carries the source format
//! all the way through ends up with a combinatorial number of paths and only
//! the common ones tested.

use std::io::{Read, Seek};

use symphonia::core::codecs::audio::{AudioDecoder as SymphoniaAudioDecoder, AudioDecoderOptions};
use symphonia::core::codecs::CodecParameters;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::{MediaSource, MediaSourceStream};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::Time;

/// What went wrong, in terms a caller can act on.
///
/// Deliberately not one opaque error. "This file is not something we can play"
/// and "the network went away mid-track" call for completely different
/// responses - one should be remembered and never retried, the other should be
/// retried and must not mark the track as broken.
#[derive(Debug)]
pub enum DecodeError {
    /// The container or codec is not supported, or the bytes are not audio.
    /// Permanent for these bytes: retrying achieves nothing.
    Unsupported(String),
    /// The stream ended or failed partway through. May well succeed on a retry,
    /// so the track must not be written off because of it.
    Interrupted(String),
    /// The audio is malformed in a way decoding cannot continue past.
    Corrupt(String),
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported(why) => write!(f, "unsupported audio: {why}"),
            Self::Interrupted(why) => write!(f, "audio stream interrupted: {why}"),
            Self::Corrupt(why) => write!(f, "corrupt audio: {why}"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// The shape of a decoded stream, known once the container is read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StreamSpec {
    /// Frames per second.
    pub sample_rate: u32,
    /// Interleaved channels per frame.
    pub channels: usize,
}

/// A decoder producing interleaved `f32` frames.
pub struct AudioDecoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn SymphoniaAudioDecoder>,
    track_id: u32,
    spec: StreamSpec,
    /// Scratch for interleaving, reused across packets so decoding a track does
    /// not allocate once per packet. Grows to the largest packet seen and then
    /// stops.
    scratch: Vec<f32>,
}

impl AudioDecoder {
    /// Open a stream, optionally hinting the container by file extension.
    ///
    /// The hint only helps probing pick a format to try first; it is never
    /// trusted over the actual bytes, because a server that names a file `.mp3`
    /// while serving AAC is common enough to plan for.
    pub fn open<R>(source: R, extension: Option<&str>) -> Result<Self, DecodeError>
    where
        R: Read + Seek + Send + Sync + 'static,
    {
        let stream = MediaSourceStream::new(Box::new(ReadSeekSource(source)), Default::default());

        let mut hint = Hint::new();
        if let Some(extension) = extension {
            hint.with_extension(extension);
        }

        let format = symphonia::default::get_probe()
            .probe(
                &hint,
                stream,
                FormatOptions::default(),
                MetadataOptions::default(),
            )
            .map_err(|e| classify(e, "probing container"))?;

        // Containers can carry video and subtitles too; take the first track
        // that is actually audio rather than assuming track zero.
        let (track_id, params) = format
            .tracks()
            .iter()
            .find_map(|track| match track.codec_params.as_ref() {
                Some(CodecParameters::Audio(audio)) => Some((track.id, audio.clone())),
                _ => None,
            })
            .ok_or_else(|| DecodeError::Unsupported("no decodable audio track".into()))?;

        // Trim encoder delay and padding, which is what lets one track meet the
        // next with no silence between them. Built by mutation rather than a
        // struct literal because the options type is non-exhaustive.
        let mut decoder_options = AudioDecoderOptions::default();
        decoder_options.gapless = true;

        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(&params, &decoder_options)
            .map_err(|e| classify(e, "creating decoder"))?;

        let sample_rate = params
            .sample_rate
            .ok_or_else(|| DecodeError::Unsupported("stream declares no sample rate".into()))?;
        let channels =
            params.channels.as_ref().map(|c| c.count()).ok_or_else(|| {
                DecodeError::Unsupported("stream declares no channel layout".into())
            })?;

        if channels == 0 {
            return Err(DecodeError::Unsupported(
                "stream declares zero channels".into(),
            ));
        }

        Ok(Self {
            format,
            decoder,
            track_id,
            spec: StreamSpec {
                sample_rate,
                channels,
            },
            scratch: Vec::new(),
        })
    }

    /// The stream's sample rate and channel count.
    pub fn spec(&self) -> StreamSpec {
        self.spec
    }

    /// Decode the next packet into interleaved `f32`, or `None` at the end.
    ///
    /// The returned slice borrows internal scratch and is valid until the next
    /// call. Callers copy it into the ring immediately, so lending rather than
    /// allocating saves a `Vec` per packet - which at roughly forty packets a
    /// second, per track, for hours, is worth not doing.
    pub fn next_frames(&mut self) -> Result<Option<&[f32]>, DecodeError> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(Some(packet)) => packet,
                Ok(None) => return Ok(None),
                Err(SymphoniaError::IoError(e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    // Some readers still signal the end this way rather than
                    // with None, so both have to mean the same thing.
                    return Ok(None);
                }
                Err(e) => return Err(classify(e, "reading packet")),
            };

            // Containers interleave tracks; anything that is not the one being
            // played is skipped rather than decoded.
            if packet.track_id != self.track_id {
                continue;
            }

            match self.decoder.decode(&packet) {
                Ok(decoded) => {
                    if decoded.frames() == 0 {
                        // An empty packet is legal - priming or padding - and
                        // is not the end of anything.
                        continue;
                    }
                    self.scratch.clear();
                    decoded.copy_to_vec_interleaved(&mut self.scratch);
                    return Ok(Some(&self.scratch));
                }
                Err(SymphoniaError::DecodeError(_)) => {
                    // A single bad packet is recoverable: symphonia asks that
                    // decoding continue, and dropping one packet is a click
                    // rather than a dead track.
                    continue;
                }
                Err(e) => return Err(classify(e, "decoding packet")),
            }
        }
    }

    /// Seek to a position in seconds, returning the frame actually landed on.
    ///
    /// Compressed formats seek to packet boundaries, so the result is usually
    /// near the request rather than exactly it. Reporting where it truly landed
    /// lets a progress display stay honest instead of showing a position the
    /// audio is not at.
    pub fn seek(&mut self, seconds: f64) -> Result<u64, DecodeError> {
        let time = Time::try_from_secs_f64(seconds).ok_or_else(|| {
            DecodeError::Unsupported(format!("{seconds} is not a representable position"))
        })?;

        let seeked = self
            .format
            .seek(
                SeekMode::Accurate,
                SeekTo::Time {
                    time,
                    track_id: Some(self.track_id),
                },
            )
            .map_err(|e| classify(e, "seeking"))?;

        // A decoder holds state from the packets it has seen; after jumping
        // somewhere else that state describes audio that is no longer adjacent.
        self.decoder.reset();

        // A negative timestamp is not a position in the audio; report the start
        // rather than wrapping it into an enormous unsigned frame number.
        Ok(seeked.actual_ts.get().max(0) as u64)
    }
}

/// Sort a symphonia error into something a caller can act on.
///
/// The distinction that matters is permanent versus transient. Marking a track
/// unplayable because a network read failed would hide it forever over a
/// problem that lasted a second.
fn classify(error: SymphoniaError, doing: &str) -> DecodeError {
    match error {
        SymphoniaError::Unsupported(why) => DecodeError::Unsupported(format!("{doing}: {why}")),
        SymphoniaError::DecodeError(why) => DecodeError::Corrupt(format!("{doing}: {why}")),
        SymphoniaError::IoError(e) => DecodeError::Interrupted(format!("{doing}: {e}")),
        SymphoniaError::SeekError(_) => {
            DecodeError::Unsupported(format!("{doing}: stream is not seekable"))
        }
        SymphoniaError::LimitError(why) => DecodeError::Corrupt(format!("{doing}: {why}")),
        SymphoniaError::ResetRequired => {
            DecodeError::Interrupted(format!("{doing}: stream changed shape"))
        }
        other => DecodeError::Corrupt(format!("{doing}: {other}")),
    }
}

/// Adapts any `Read + Seek` into symphonia's `MediaSource`.
struct ReadSeekSource<R>(R);

impl<R: Read> Read for ReadSeekSource<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0.read(buf)
    }
}

impl<R: Seek> Seek for ReadSeekSource<R> {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        self.0.seek(pos)
    }
}

impl<R: Read + Seek + Send + Sync> MediaSource for ReadSeekSource<R> {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// Build a WAV in memory so the tests do not depend on a fixture file, and
    /// so the expected samples are known exactly rather than approximately.
    fn wav(channels: u16, sample_rate: u32, samples: &[i16]) -> Vec<u8> {
        let data_bytes = (samples.len() * 2) as u32;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_bytes).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes()); // PCM
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        let block_align = channels * 2;
        out.extend_from_slice(&(sample_rate * block_align as u32).to_le_bytes());
        out.extend_from_slice(&block_align.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes()); // bits
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_bytes.to_le_bytes());
        for sample in samples {
            out.extend_from_slice(&sample.to_le_bytes());
        }
        out
    }

    fn collect(decoder: &mut AudioDecoder) -> Vec<f32> {
        let mut all = Vec::new();
        while let Some(frames) = decoder.next_frames().expect("decode failed") {
            all.extend_from_slice(frames);
        }
        all
    }

    #[test]
    fn it_reads_the_stream_shape() {
        let bytes = wav(2, 44_100, &[0; 64]);
        let decoder =
            AudioDecoder::open(Cursor::new(bytes), Some("wav")).expect("should open a wav");

        let spec = decoder.spec();
        assert_eq!(spec.sample_rate, 44_100);
        assert_eq!(spec.channels, 2);
    }

    #[test]
    fn samples_come_out_interleaved_in_order() {
        // Left ramps up, right ramps down, so a swap or a planar/interleaved
        // mix-up is visible rather than merely suspicious.
        let bytes = wav(2, 8_000, &[0, 32_000, 8_000, 24_000, 16_000, 16_000]);
        let mut decoder = AudioDecoder::open(Cursor::new(bytes), Some("wav")).unwrap();

        let samples = collect(&mut decoder);
        assert_eq!(samples.len(), 6, "three stereo frames");
        assert!(
            samples[0].abs() < 0.001,
            "left of frame 0 should be silence"
        );
        assert!(
            samples[1] > 0.9,
            "right of frame 0 should be near full scale"
        );
        assert!(samples[2] > 0.2 && samples[2] < 0.3, "left of frame 1");
    }

    /// Everything must arrive as f32 in [-1, 1] whatever the source format,
    /// because nothing downstream knows what the file was.
    #[test]
    fn integer_sources_are_normalised_to_unit_float() {
        let bytes = wav(1, 8_000, &[i16::MIN, 0, i16::MAX]);
        let mut decoder = AudioDecoder::open(Cursor::new(bytes), Some("wav")).unwrap();

        let samples = collect(&mut decoder);
        assert_eq!(samples.len(), 3);
        assert!(
            (samples[0] + 1.0).abs() < 0.001,
            "full negative should be -1.0"
        );
        assert!(samples[1].abs() < 0.001, "zero should be 0.0");
        assert!(
            (samples[2] - 1.0).abs() < 0.001,
            "full positive should be ~1.0"
        );
    }

    #[test]
    fn mono_stays_mono_rather_than_being_widened() {
        let bytes = wav(1, 44_100, &[100, 200, 300, 400]);
        let mut decoder = AudioDecoder::open(Cursor::new(bytes), Some("wav")).unwrap();

        assert_eq!(decoder.spec().channels, 1);
        assert_eq!(collect(&mut decoder).len(), 4);
    }

    /// Bytes that are not audio are permanently unplayable, and saying so is
    /// what stops the caller retrying forever.
    #[test]
    fn rubbish_is_reported_as_unsupported_rather_than_interrupted() {
        let bytes = vec![0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07];
        let error = AudioDecoder::open(Cursor::new(bytes), None)
            .err()
            .expect("random bytes should not open");

        assert!(
            matches!(error, DecodeError::Unsupported(_)),
            "expected Unsupported, got {error:?}"
        );
    }

    /// A file named one thing and containing another is common from real
    /// servers; the bytes have to win.
    #[test]
    fn a_wrong_extension_does_not_prevent_playback() {
        let bytes = wav(2, 44_100, &[1_000; 32]);
        let mut decoder = AudioDecoder::open(Cursor::new(bytes), Some("mp3"))
            .expect("a mislabelled wav should still open");

        assert_eq!(decoder.spec().channels, 2);
        assert!(!collect(&mut decoder).is_empty());
    }

    #[test]
    fn a_stream_ends_by_returning_none_rather_than_erroring() {
        let bytes = wav(1, 8_000, &[1, 2, 3, 4]);
        let mut decoder = AudioDecoder::open(Cursor::new(bytes), Some("wav")).unwrap();

        while decoder.next_frames().unwrap().is_some() {}
        assert!(
            decoder.next_frames().unwrap().is_none(),
            "reading past the end should keep saying None"
        );
    }

    /// The contract is not that a seek is exact - compressed and even PCM
    /// readers land on block boundaries, and this one lands 544 frames early
    /// on a request for frame 4000. The contract is that the position it
    /// *reports* is the position the audio is actually at, because a progress
    /// display built on a number that is merely close drifts visibly.
    ///
    /// The fixture encodes its own frame index (sample N holds N % 1000), so
    /// the first sample decoded after a seek proves whether the reported frame
    /// is the truth or an approximation of it.
    #[test]
    fn a_seek_reports_the_position_the_audio_is_really_at() {
        let samples: Vec<i16> = (0..8_000).map(|v| (v % 1000) as i16).collect();
        let bytes = wav(1, 8_000, &samples);
        let mut decoder = AudioDecoder::open(Cursor::new(bytes), Some("wav")).unwrap();

        let landed = decoder.seek(0.5).expect("wav should seek");
        assert!(
            landed <= 4_000,
            "overshot the request and silently skipped audio: {landed}"
        );

        let first = decoder
            .next_frames()
            .expect("decoding after a seek should work")
            .expect("there should be audio after 0.5s of an 1s file")[0];

        let expected = (landed % 1000) as f32 / 32_768.0;
        assert!(
            (first - expected).abs() < 0.001,
            "reported frame {landed} but the audio there was {first}, not {expected}"
        );
    }
}

//! Handing finished samples to an operating system.
//!
//! This is the sink, and it is deliberately the least interesting file in the
//! crate. Everything that decides how music sounds has already happened by the
//! time audio arrives here: decoding, normalisation, tone, and the order those
//! were applied in. What is left is asking an OS for a stream and copying into
//! whatever buffer it provides.
//!
//! Keeping it thin is the point rather than an accident. The moment a sink
//! starts making decisions - resampling one way on one platform, choosing a
//! different buffer size, applying its own volume curve - two devices playing
//! the same file stop sounding the same, and the shared crate above it has been
//! wasted.
//!
//! # Sample rate is a decision, so it is not made here
//!
//! A device that cannot run at the source's rate needs the audio resampled, and
//! resampling is emphatically a decision: it changes the samples. Doing it
//! per-platform with whatever the OS offers is how two devices end up sounding
//! different. So [`choose_config`] is a pure function with its own tests, and a
//! device that cannot be driven at the source rate is reported as such rather
//! than quietly played at the wrong speed - which does not sound like a bug, it
//! sounds like the recording is in the wrong key.

use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig, SupportedStreamConfigRange};

use crate::ring::Consumer;

/// Why a device could not be opened.
#[derive(Debug)]
pub enum SinkError {
    /// No output device at all.
    NoDevice,
    /// The device exists but cannot be queried.
    Unavailable(String),
    /// No configuration matches the audio, and resampling would be required.
    ///
    /// Named rather than worked around, because silently playing at a rate the
    /// audio was not recorded at shifts its pitch.
    RateUnsupported {
        /// The rate the audio is recorded at.
        wanted: u32,
        /// The rates the device will actually run at.
        available: Vec<u32>,
    },
    /// The OS refused to start the stream.
    Refused(String),
}

impl std::fmt::Display for SinkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoDevice => write!(f, "no audio output device"),
            Self::Unavailable(why) => write!(f, "audio device unavailable: {why}"),
            Self::RateUnsupported { wanted, available } => {
                write!(f, "device cannot play {wanted} Hz; it offers {available:?}")
            }
            Self::Refused(why) => write!(f, "audio device refused the stream: {why}"),
        }
    }
}

impl std::error::Error for SinkError {}

/// Pick a stream configuration for `sample_rate` and `channels`.
///
/// Pure and separately tested, because this is the one judgement the sink makes
/// and judgements that live inside a device callback are judgements nobody ever
/// verifies.
///
/// Preference order:
/// 1. The exact source rate, so no resampling is needed at all.
/// 2. The same rate inside a supported range.
/// 3. Nothing - report [`SinkError::RateUnsupported`] rather than substitute.
pub fn choose_config(
    supported: &[SupportedStreamConfigRange],
    sample_rate: u32,
    channels: u16,
) -> Result<StreamConfig, SinkError> {
    // Only configurations with at least as many channels as the audio can carry
    // it; a stereo file into a mono device would silently lose a side.
    let usable: Vec<&SupportedStreamConfigRange> = supported
        .iter()
        .filter(|range| range.channels() >= channels)
        .collect();

    let exact = usable.iter().find(|range| {
        range.min_sample_rate() <= sample_rate && sample_rate <= range.max_sample_rate()
    });

    if exact.is_some() {
        return Ok(StreamConfig {
            channels,
            sample_rate,
            buffer_size: cpal::BufferSize::Default,
        });
    }

    let mut available: Vec<u32> = usable
        .iter()
        .flat_map(|range| [range.min_sample_rate(), range.max_sample_rate()])
        .collect();
    available.sort_unstable();
    available.dedup();

    Err(SinkError::RateUnsupported {
        wanted: sample_rate,
        available,
    })
}

/// A running output stream. Dropping it stops playback.
pub struct Sink {
    stream: cpal::Stream,
    /// Reported by the callback so a caller can notice the decoder falling
    /// behind. An `AtomicUsize` rather than a callback, because invoking
    /// arbitrary code from the audio thread is how real-time deadlines get
    /// missed.
    starvations: Arc<std::sync::atomic::AtomicUsize>,
}

impl Sink {
    /// Open the default output device and start playing from `consumer`.
    pub fn open(consumer: Consumer, sample_rate: u32, channels: u16) -> Result<Self, SinkError> {
        let host = cpal::default_host();
        let device = host.default_output_device().ok_or(SinkError::NoDevice)?;

        let supported: Vec<SupportedStreamConfigRange> = device
            .supported_output_configs()
            .map_err(|e| SinkError::Unavailable(e.to_string()))?
            .filter(|range| range.sample_format() == SampleFormat::F32)
            .collect();

        let config = choose_config(&supported, sample_rate, channels)?;

        let starvations = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = Arc::clone(&starvations);

        // cpal wants the callback to be Send, and the consumer is only touched
        // from inside it. The mutex is never contended - nothing else holds it -
        // so it costs an uncontended atomic per callback and buys the borrow
        // checker's agreement without any unsafe.
        let consumer = Mutex::new(consumer);

        let stream = device
            .build_output_stream(
                config,
                move |out: &mut [f32], _| {
                    // A poisoned lock would mean a previous callback panicked.
                    // Silence is the only safe answer; the alternative is
                    // panicking again on the audio thread.
                    let Ok(mut consumer) = consumer.lock() else {
                        out.fill(0.0);
                        return;
                    };
                    let outcome = consumer.read(out);
                    if outcome.starved {
                        counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                },
                move |error| {
                    // There is nothing useful to do from here; the stream is
                    // already broken. Recording it beats swallowing it.
                    eprintln!("mozz audio stream error: {error}");
                },
                None,
            )
            .map_err(|e| SinkError::Refused(e.to_string()))?;

        stream
            .play()
            .map_err(|e| SinkError::Refused(e.to_string()))?;

        Ok(Self {
            stream,
            starvations,
        })
    }

    /// How many callbacks have run out of audio since opening.
    ///
    /// Non-zero means the decoder is not keeping up, which is audible as a
    /// stutter and is worth surfacing rather than leaving to be guessed at.
    pub fn starvations(&self) -> usize {
        self.starvations.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Pause the device without discarding what is queued.
    pub fn pause(&self) -> Result<(), SinkError> {
        self.stream
            .pause()
            .map_err(|e| SinkError::Refused(e.to_string()))
    }

    /// Resume after [`Sink::pause`].
    pub fn resume(&self) -> Result<(), SinkError> {
        self.stream
            .play()
            .map_err(|e| SinkError::Refused(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn range(channels: u16, min: u32, max: u32) -> SupportedStreamConfigRange {
        SupportedStreamConfigRange::new(
            channels,
            min,
            max,
            cpal::SupportedBufferSize::Unknown,
            SampleFormat::F32,
        )
    }

    #[test]
    fn an_exactly_supported_rate_is_used_unchanged() {
        let supported = [range(2, 44_100, 44_100), range(2, 48_000, 48_000)];
        let config = choose_config(&supported, 44_100, 2).expect("44.1 kHz is offered");

        assert_eq!(config.sample_rate, 44_100);
        assert_eq!(config.channels, 2);
    }

    #[test]
    fn a_rate_inside_a_supported_range_is_used() {
        let supported = [range(2, 8_000, 192_000)];
        let config = choose_config(&supported, 96_000, 2).expect("inside the range");
        assert_eq!(config.sample_rate, 96_000);
    }

    /// The important one. Substituting a rate the audio was not recorded at
    /// shifts its pitch, which does not sound like a bug - it sounds like the
    /// recording is in the wrong key, and it would be blamed on the file.
    #[test]
    fn an_unsupported_rate_is_reported_rather_than_substituted() {
        let supported = [range(2, 48_000, 48_000)];
        let error = choose_config(&supported, 44_100, 2)
            .expect_err("44.1 kHz is not offered and must not be faked");

        match error {
            SinkError::RateUnsupported { wanted, available } => {
                assert_eq!(wanted, 44_100);
                assert_eq!(available, vec![48_000]);
            }
            other => panic!("expected RateUnsupported, got {other:?}"),
        }
    }

    /// A stereo file into a mono device would silently lose a side, so a
    /// configuration that cannot carry the channels does not count as usable.
    #[test]
    fn a_device_with_too_few_channels_is_not_chosen() {
        let supported = [range(1, 44_100, 44_100)];
        let error = choose_config(&supported, 44_100, 2).expect_err("mono cannot carry stereo");
        assert!(matches!(error, SinkError::RateUnsupported { .. }));
    }

    #[test]
    fn a_device_with_more_channels_than_needed_is_fine() {
        let supported = [range(8, 44_100, 44_100)];
        let config = choose_config(&supported, 44_100, 2).expect("8 channels can carry 2");
        assert_eq!(config.channels, 2, "asks for only what the audio has");
    }

    #[test]
    fn a_device_offering_nothing_reports_what_it_wanted() {
        let error = choose_config(&[], 44_100, 2).expect_err("no configs");
        match error {
            SinkError::RateUnsupported { wanted, available } => {
                assert_eq!(wanted, 44_100);
                assert!(available.is_empty());
            }
            other => panic!("expected RateUnsupported, got {other:?}"),
        }
    }
}

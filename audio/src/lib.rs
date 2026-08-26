#![forbid(unsafe_code)]
#![warn(missing_docs)]

//! Pure audio decisions shared by every Mozz shell.
//!
//! The platform sink starts after this crate has produced finished samples. That
//! boundary keeps CoreAudio, WASAPI, AAudio and the browser out of the decisions
//! that change how a track sounds, so two devices are not allowed to drift merely
//! because they hand the buffer to different operating systems.

pub mod decode;
pub mod ring;

use std::f64::consts::PI;

/// The ten ISO centre frequencies used by Mozz's existing equaliser surfaces.
///
/// Keeping the layout here prevents one shell from drawing the familiar ten
/// sliders while another shell silently filters a different set of bands.
pub const ISO_CENTRES_HZ: [f64; 10] = [
    31.0, 62.0, 125.0, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0, 16_000.0,
];

/// The lowest gain the existing settings UI allows for an equaliser band.
///
/// The DSP can represent larger cuts, but carrying the app's current range into
/// the shared crate makes presets and persisted settings mean the same thing on
/// every shell.
pub const MIN_EQ_GAIN_DB: f64 = -12.0;

/// The highest gain the existing settings UI allows for an equaliser band.
///
/// Boosts are bounded before they reach the filter bank so a malformed setting
/// cannot make one platform much louder than another.
pub const MAX_EQ_GAIN_DB: f64 = 12.0;

/// The default upper bound for ReplayGain's linear multiplier.
///
/// This is Swift's existing +12.04 dB cap. It is not a tone-shaping control; it
/// exists so one malformed loudness tag cannot turn into an extreme multiplier.
pub const DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE: f64 = 4.0;

/// Which ReplayGain tag should be honoured for the current playback mode.
///
/// Keeping the mode in the shared core prevents one shell from treating "album"
/// as a hard requirement while another shell silently falls back to the track tag.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReplayGainMode {
    /// Ignore both ReplayGain tags while still applying the ReplayGain preamp.
    ///
    /// The desktop engine has shipped this behaviour, so "off" means "do not
    /// normalise by metadata" rather than "disable the user's ReplayGain preamp".
    Off,
    /// Prefer the per-track tag and fall back to the album tag when it is absent.
    ///
    /// This is the mode for playlists where adjacent tracks may come from
    /// unrelated albums and need their own loudness correction.
    Track,
    /// Prefer the album tag and fall back to the track tag when it is absent.
    ///
    /// This keeps an album's intentional internal dynamics when that album-level
    /// tag is available without making an untagged album play silently or oddly.
    Album,
}

/// ReplayGain inputs that determine one scalar for a decoded source.
///
/// The ReplayGain preamp here is separate from the equaliser preamp on
/// [`EqualizerProfile`]. This value is added to the loudness-normalisation dB
/// before conversion to a scalar; the EQ preamp is applied later after the filter
/// bank, so folding the two together would make one setting change the other
/// feature's contract.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReplayGainSettings {
    /// The mode chooses which metadata tag is preferred before fallback.
    pub mode: ReplayGainMode,
    /// The per-track ReplayGain tag in dB, when the source exposed one.
    pub track_gain_db: Option<f64>,
    /// The per-album ReplayGain tag in dB, when the source exposed one.
    pub album_gain_db: Option<f64>,
    /// The ReplayGain preamp in dB, applied before the value becomes linear.
    pub preamp_db: f64,
    /// The source peak after decoding, used to keep a boost from clipping.
    pub peak: Option<f64>,
    /// The maximum linear multiplier allowed before peak limiting runs.
    ///
    /// The default is Swift's existing `4.0` cap. Use positive infinity only when
    /// deliberately reproducing the desktop engine's historical uncapped output.
    /// Other non-finite values fall back to the default, and negative values act
    /// as zero, because an invalid safety bound should fail closed.
    pub maximum_scale: f64,
}

impl ReplayGainSettings {
    /// Builds settings that produce unity gain until a caller supplies metadata.
    ///
    /// The default cap matches the Swift implementation so malformed tags are
    /// bounded even before a shell exposes a setting for this value.
    pub fn new(mode: ReplayGainMode) -> Self {
        Self {
            mode,
            track_gain_db: None,
            album_gain_db: None,
            preamp_db: 0.0,
            peak: None,
            maximum_scale: DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE,
        }
    }

    fn selected_gain_db(self) -> Option<f64> {
        match self.mode {
            ReplayGainMode::Off => None,
            ReplayGainMode::Track => self.track_gain_db.or(self.album_gain_db),
            ReplayGainMode::Album => self.album_gain_db.or(self.track_gain_db),
        }
    }
}

impl Default for ReplayGainSettings {
    fn default() -> Self {
        Self::new(ReplayGainMode::Off)
    }
}

/// Converts ReplayGain settings into the multiplier applied to decoded samples.
///
/// The order is fixed because this is where the shipping implementations already
/// drifted. First the mode selects track, album, fallback or no tag. Then the
/// ReplayGain preamp is added in dB and converted to a linear scalar. Swift's cap
/// is applied next to bound malformed tags. Peak limiting is applied last and is
/// new behaviour: when a boost would push the declared peak above full scale, the
/// boost is reduced, and samples that were not going to clip are not made quieter.
/// Applying the peak rule last makes it the final clipping guard; the opposite
/// order is numerically the same for today's two reducing limits, but it would
/// make the malformed-tag cap look like the safety rail even when it is larger
/// than the source's actual headroom.
pub fn replay_gain_scale(settings: ReplayGainSettings) -> f32 {
    let selected_gain_db = settings.selected_gain_db().unwrap_or(0.0);
    let total_db = finite_or(settings.preamp_db, 0.0) + finite_or(selected_gain_db, 0.0);

    let mut scale = db_to_linear(total_db);
    if !scale.is_finite() || scale < 0.0 {
        return 1.0;
    }

    if !(settings.maximum_scale.is_infinite() && settings.maximum_scale.is_sign_positive()) {
        let maximum_scale =
            finite_or(settings.maximum_scale, DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE).max(0.0);
        scale = scale.clamp(0.0, maximum_scale);
    }

    if let Some(peak) = settings.peak.filter(|peak| peak.is_finite() && *peak > 0.0) {
        let maximum_without_clipping = 1.0 / peak;
        if scale * peak > 1.0 {
            scale = maximum_without_clipping;
        }
    }

    scale as f32
}

/// Applies ReplayGain in place and returns the multiplier that was used.
///
/// A unity result is a deliberate no-op, not a multiplication by one, so the
/// buffer remains bit-for-bit untouched when the library has no loudness change
/// to make. That distinction matters for tests that prove the sink is not making
/// hidden choices after the core is done.
pub fn apply_replay_gain(samples: &mut [f32], settings: ReplayGainSettings) -> f32 {
    let scale = replay_gain_scale(settings);
    if scale == 1.0 {
        return scale;
    }

    for sample in samples {
        *sample *= scale;
    }

    scale
}

/// One Direct Form I biquad filter section for one channel.
///
/// A peaking equaliser band is a second-order IIR filter, which means its state
/// is part of the sound. Keeping that state on the section, rather than inside a
/// temporary processing call, prevents clicks at buffer boundaries.
#[derive(Clone, Debug)]
pub struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
}

impl Biquad {
    /// Builds a unity section that can later be configured as a peaking band.
    ///
    /// Starting at unity means a filter bank can be allocated before settings
    /// arrive without ever changing a sample by accident.
    pub fn unity() -> Self {
        Self {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    /// Builds a peaking filter from the same cookbook formulae as the desktop app.
    ///
    /// Coefficients are set without priming the history, because a settings change
    /// during playback should not also pretend that a seek happened.
    pub fn peaking(sample_rate_hz: f64, frequency_hz: f64, gain_db: f64, q: f64) -> Self {
        let mut biquad = Self::unity();
        biquad.set_peaking(sample_rate_hz, frequency_hz, gain_db, q);
        biquad
    }

    /// Reconfigures the section as a peaking EQ band while preserving history.
    ///
    /// The existing desktop engine resets state only at discontinuities such as a
    /// seek or a new source. Mirroring that behaviour avoids adding an artificial
    /// click when the user drags an EQ slider.
    pub fn set_peaking(&mut self, sample_rate_hz: f64, frequency_hz: f64, gain_db: f64, q: f64) {
        let sample_rate_hz = finite_or(sample_rate_hz, 48_000.0).max(2.0);
        let q = if q.is_finite() && q > 0.0 { q } else { 0.0001 };
        let upper_frequency = (sample_rate_hz * 0.5 - 1.0).max(1.0);
        let frequency_hz = finite_or(frequency_hz, 1.0).clamp(1.0, upper_frequency);
        let gain_db = finite_or(gain_db, 0.0);

        let a = 10.0_f64.powf(gain_db / 40.0);
        let w0 = 2.0 * PI * frequency_hz / sample_rate_hz;
        let cos = w0.cos();
        let alpha = w0.sin() / (2.0 * q);

        let b0 = 1.0 + alpha * a;
        let b1 = -2.0 * cos;
        let b2 = 1.0 - alpha * a;
        let a0 = 1.0 + alpha / a;
        let a1 = -2.0 * cos;
        let a2 = 1.0 - alpha / a;

        self.b0 = b0 / a0;
        self.b1 = b1 / a0;
        self.b2 = b2 / a0;
        self.a1 = a1 / a0;
        self.a2 = a2 / a0;
    }

    /// Clears history after a real stream discontinuity.
    ///
    /// A seek or source change makes the old samples unrelated to the next ones,
    /// so carrying the previous history across that boundary would smear two
    /// different moments of audio together.
    pub fn reset(&mut self) {
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }

    /// Filters one sample and advances the section history.
    ///
    /// This scalar path exists so interleaved equaliser processing can keep each
    /// channel's history separate without allocating scratch buffers.
    pub fn process_sample(&mut self, input: f32) -> f32 {
        let x0 = f64::from(input);
        let y0 = self.b0 * x0 + self.b1 * self.x1 + self.b2 * self.x2
            - self.a1 * self.y1
            - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x0;
        self.y2 = self.y1;
        self.y1 = y0;
        y0 as f32
    }

    /// Filters a contiguous mono buffer in place.
    ///
    /// The method does not allocate; callers that need many channels should own
    /// many sections and reuse them for every callback.
    pub fn process(&mut self, samples: &mut [f32]) {
        for sample in samples {
            *sample = self.process_sample(*sample);
        }
    }
}

impl Default for Biquad {
    fn default() -> Self {
        Self::unity()
    }
}

/// One peaking band in the shared equaliser.
///
/// The type mirrors the existing desktop engine so settings can move into the
/// core without changing what a saved profile means.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EqualizerBand {
    /// The centre frequency selected by the graphic EQ layout.
    pub frequency_hz: f64,
    /// The cut or boost applied at the centre frequency.
    pub gain_db: f64,
    /// The quality factor that controls how wide the band is.
    pub q: f64,
}

impl EqualizerBand {
    /// Creates a peaking band with the existing app's default one-octave-ish width.
    ///
    /// Most Mozz settings store only gains. Providing the default here keeps every
    /// shell from inventing its own width while expanding those settings.
    pub fn new(frequency_hz: f64, gain_db: f64) -> Self {
        Self {
            frequency_hz,
            gain_db,
            q: 1.0,
        }
    }
}

/// The ten-band profile currently exposed by Mozz settings.
///
/// The gains are clamped at construction because the UI range is part of the
/// profile contract, not a rendering detail of one shell.
#[derive(Clone, Debug, PartialEq)]
pub struct EqualizerProfile {
    gains_db: [f64; ISO_CENTRES_HZ.len()],
    preamp_db: f64,
}

impl EqualizerProfile {
    /// Builds a flat profile that leaves the signal unchanged.
    ///
    /// This is the stable default when a server, device, or settings file has no
    /// equaliser preference yet.
    pub fn flat() -> Self {
        Self {
            gains_db: [0.0; ISO_CENTRES_HZ.len()],
            preamp_db: 0.0,
        }
    }

    /// Builds a profile from the app's ten persisted slider values.
    ///
    /// The exact array length prevents accidentally dropping or adding a band and
    /// then getting a different sound only on the platform that made the mistake.
    pub fn from_gains(gains_db: [f64; ISO_CENTRES_HZ.len()], preamp_db: f64) -> Self {
        let mut normalized = [0.0; ISO_CENTRES_HZ.len()];
        for (index, gain) in gains_db.into_iter().enumerate() {
            normalized[index] = clamp_gain(gain);
        }

        Self {
            gains_db: normalized,
            preamp_db: clamp_gain(preamp_db),
        }
    }

    /// Returns the clamped gain for one band.
    ///
    /// Callers use this when they need to redraw a settings surface from the
    /// canonical profile rather than trusting platform-local clamping.
    pub fn gain_db(&self, index: usize) -> Option<f64> {
        self.gains_db.get(index).copied()
    }

    /// Returns the clamped preamp applied after all bands.
    ///
    /// Preamp lives with the profile because it is part of the equaliser's sound,
    /// not a volume control owned by a sink.
    pub fn preamp_db(&self) -> f64 {
        self.preamp_db
    }

    /// Expands the fixed slider profile into peaking bands.
    ///
    /// Allocation happens here, away from the processing path, because callbacks
    /// must be able to reuse an already-built filter bank.
    pub fn bands(&self) -> Vec<EqualizerBand> {
        ISO_CENTRES_HZ
            .into_iter()
            .zip(self.gains_db)
            .map(|(frequency_hz, gain_db)| EqualizerBand::new(frequency_hz, gain_db))
            .collect()
    }
}

impl Default for EqualizerProfile {
    fn default() -> Self {
        Self::flat()
    }
}

/// A reusable equaliser for interleaved PCM buffers.
///
/// Each channel owns a separate copy of every band. Sharing state between the
/// left and right channels would fold one channel's past samples into the other
/// channel's future samples and move the stereo image.
#[derive(Clone, Debug)]
pub struct Equalizer {
    channels: usize,
    bands: Vec<EqualizerBand>,
    filters: Vec<Biquad>,
    enabled: bool,
    preamp: f32,
}

impl Equalizer {
    /// Allocates the filter bank for a sample format that will be reused.
    ///
    /// The returned equaliser is disabled and therefore starts as an exact
    /// pass-through until a profile is configured.
    pub fn new(sample_rate_hz: f64, channels: usize) -> Self {
        Self::with_bands(sample_rate_hz, channels, &[], false, 0.0)
    }

    /// Allocates a ten-band equaliser matching the current Mozz settings layout.
    ///
    /// This constructor is the normal path for persisted profiles, because it
    /// prevents a shell from accidentally choosing a different set of centres.
    pub fn from_profile(
        sample_rate_hz: f64,
        channels: usize,
        profile: &EqualizerProfile,
        enabled: bool,
    ) -> Self {
        let bands = profile.bands();
        Self::with_bands(
            sample_rate_hz,
            channels,
            &bands,
            enabled,
            profile.preamp_db(),
        )
    }

    /// Allocates an equaliser from explicit bands.
    ///
    /// Custom bands are useful for tests and future presets, but allocation still
    /// happens only before processing so the callback path stays predictable.
    pub fn with_bands(
        sample_rate_hz: f64,
        channels: usize,
        bands: &[EqualizerBand],
        enabled: bool,
        preamp_db: f64,
    ) -> Self {
        let channels = channels.max(1);
        let mut filters = Vec::with_capacity(bands.len() * channels);
        for band in bands {
            for _ in 0..channels {
                filters.push(Biquad::peaking(
                    sample_rate_hz,
                    band.frequency_hz,
                    band.gain_db,
                    band.q,
                ));
            }
        }

        Self {
            channels,
            bands: bands.to_vec(),
            filters,
            enabled: enabled && !bands.is_empty(),
            preamp: db_to_linear(clamp_gain(preamp_db)) as f32,
        }
    }

    /// Reports whether processing currently changes samples.
    ///
    /// A disabled equaliser remains allocated so toggling a setting does not make
    /// the next audio callback allocate a new filter bank.
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// Clears every channel's filter history after a seek or source change.
    ///
    /// The equaliser has memory by design, but that memory is valid only across
    /// continuous buffers from the same stream.
    pub fn reset(&mut self) {
        for filter in &mut self.filters {
            filter.reset();
        }
    }

    /// Filters interleaved samples in place without allocating.
    ///
    /// The buffer length may contain a partial trailing frame; those samples are
    /// ignored because guessing the missing channels would be another platform
    /// decision. Normal engine buffers are frame-aligned.
    pub fn process(&mut self, interleaved: &mut [f32]) {
        if !self.enabled {
            return;
        }

        let frames = interleaved.len() / self.channels;
        for frame in 0..frames {
            let base = frame * self.channels;
            for channel in 0..self.channels {
                let mut sample = interleaved[base + channel];
                for band_index in 0..self.bands.len() {
                    let filter_index = band_index * self.channels + channel;
                    sample = self.filters[filter_index].process_sample(sample);
                }
                interleaved[base + channel] = sample * self.preamp;
            }
        }
    }
}

fn db_to_linear(db: f64) -> f64 {
    10.0_f64.powf(db / 20.0)
}

fn clamp_gain(value: f64) -> f64 {
    if value.is_finite() {
        value.clamp(MIN_EQ_GAIN_DB, MAX_EQ_GAIN_DB)
    } else {
        0.0
    }
}

fn finite_or(value: f64, fallback: f64) -> f64 {
    if value.is_finite() {
        value
    } else {
        fallback
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_close(actual: f32, expected: f32, tolerance: f32) {
        assert!(
            (actual - expected).abs() <= tolerance,
            "expected {actual} to be within {tolerance} of {expected}"
        );
    }

    fn assert_slices_close(actual: &[f32], expected: &[f32], tolerance: f32) {
        assert_eq!(actual.len(), expected.len());
        for (index, (actual, expected)) in actual.iter().zip(expected).enumerate() {
            assert!(
                (*actual - *expected).abs() <= tolerance,
                "sample {index}: expected {actual} to be within {tolerance} of {expected}"
            );
        }
    }

    fn sine(sample_rate_hz: f64, frames: usize, frequency_hz: f64, amplitude: f32) -> Vec<f32> {
        (0..frames)
            .map(|frame| {
                let phase = 2.0 * PI * frequency_hz * frame as f64 / sample_rate_hz;
                (f64::from(amplitude) * phase.sin()) as f32
            })
            .collect()
    }

    fn legacy_swift_linear(gain_db: f64, preamp_db: f64, max_scalar: f64) -> f32 {
        let scalar = 10.0_f64.powf((gain_db + preamp_db) / 20.0) as f32;
        if !scalar.is_finite() {
            return 1.0;
        }

        scalar.max(0.0).min(max_scalar as f32)
    }

    fn legacy_desktop_linear(
        mode: ReplayGainMode,
        preamp_db: f64,
        track_db: Option<f64>,
        album_db: Option<f64>,
    ) -> f32 {
        if mode == ReplayGainMode::Off {
            return db_to_linear(preamp_db) as f32;
        }

        let gain = match mode {
            ReplayGainMode::Off => None,
            ReplayGainMode::Track => track_db.or(album_db),
            ReplayGainMode::Album => album_db.or(track_db),
        }
        .unwrap_or(0.0);

        db_to_linear(preamp_db + gain) as f32
    }

    #[test]
    fn replay_gain_matches_swift_linear_scalar_when_using_swift_contract() {
        let cases = [
            (0.0, 0.0, 4.0),
            (-6.0, 0.0, 4.0),
            (6.0, 0.0, 4.0),
            (6.0, 6.0, 4.0),
            (8.0, 6.0, 4.0),
            (3.0, 3.0, 1.5),
        ];

        for (gain_db, preamp_db, maximum_scale) in cases {
            let settings = ReplayGainSettings {
                mode: ReplayGainMode::Track,
                track_gain_db: Some(gain_db),
                album_gain_db: None,
                preamp_db,
                peak: None,
                maximum_scale,
            };

            assert_close(
                replay_gain_scale(settings),
                legacy_swift_linear(gain_db, preamp_db, maximum_scale),
                0.000_001,
            );
        }
    }

    #[test]
    fn replay_gain_matches_desktop_mode_and_fallback_when_uncapped() {
        let cases = [
            (ReplayGainMode::Off, 6.0, Some(20.0), Some(-20.0)),
            (ReplayGainMode::Track, 0.0, Some(-6.0), Some(3.0)),
            (ReplayGainMode::Track, 1.0, None, Some(-3.0)),
            (ReplayGainMode::Album, 1.0, Some(-3.0), None),
            (ReplayGainMode::Album, -2.0, Some(6.0), Some(3.0)),
            (ReplayGainMode::Track, -1.0, None, None),
        ];

        for (mode, preamp_db, track_gain_db, album_gain_db) in cases {
            let settings = ReplayGainSettings {
                mode,
                track_gain_db,
                album_gain_db,
                preamp_db,
                peak: None,
                maximum_scale: f64::INFINITY,
            };

            assert_close(
                replay_gain_scale(settings),
                legacy_desktop_linear(mode, preamp_db, track_gain_db, album_gain_db),
                0.000_001,
            );
        }
    }

    #[test]
    fn legacy_replay_gain_disagreement_is_the_swift_cap() {
        let cases = [(-6.0, 0.0), (6.0, 0.0), (6.0, 6.0), (8.0, 6.0), (20.0, 0.0)];

        for (track_gain_db, preamp_db) in cases {
            let capped = ReplayGainSettings {
                mode: ReplayGainMode::Track,
                track_gain_db: Some(track_gain_db),
                album_gain_db: None,
                preamp_db,
                peak: None,
                maximum_scale: DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE,
            };
            let uncapped = ReplayGainSettings {
                maximum_scale: f64::INFINITY,
                ..capped
            };

            let swift =
                legacy_swift_linear(track_gain_db, preamp_db, DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE);
            let desktop =
                legacy_desktop_linear(ReplayGainMode::Track, preamp_db, Some(track_gain_db), None);
            let raw_exceeds_swift_cap =
                db_to_linear(track_gain_db + preamp_db) > DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE;

            assert_close(replay_gain_scale(capped), swift, 0.000_001);
            assert_close(replay_gain_scale(uncapped), desktop, 0.000_001);
            assert_eq!((swift - desktop).abs() > 0.000_001, raw_exceeds_swift_cap);
        }
    }

    #[test]
    fn replay_gain_application_uses_the_selected_scale_in_place() {
        let mut samples = [0.25_f32, -0.5, 0.0, 1.0];
        let scale = apply_replay_gain(
            &mut samples,
            ReplayGainSettings {
                mode: ReplayGainMode::Track,
                track_gain_db: Some(-3.0),
                album_gain_db: None,
                preamp_db: 0.0,
                peak: None,
                maximum_scale: DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE,
            },
        );

        assert_close(scale, 0.707_945_76, 0.000_001);
        assert_slices_close(
            &samples,
            &[0.176_986_44, -0.353_972_88, 0.0, 0.707_945_76],
            0.000_001,
        );
    }

    #[test]
    fn missing_replay_gain_leaves_samples_untouched() {
        let mut samples = [f32::NAN, -0.25, 0.25, 0.75];
        let before = samples;

        let scale = apply_replay_gain(
            &mut samples,
            ReplayGainSettings {
                mode: ReplayGainMode::Track,
                track_gain_db: None,
                album_gain_db: None,
                preamp_db: 0.0,
                peak: Some(0.25),
                maximum_scale: DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE,
            },
        );

        assert_eq!(scale, 1.0);
        assert_eq!(samples[0].to_bits(), before[0].to_bits());
        assert_eq!(samples[1..], before[1..]);
    }

    #[test]
    fn replay_gain_peak_limiting_prevents_clipping() {
        let mut samples = [0.8_f32, -0.8, 0.4, -0.2];

        let settings = ReplayGainSettings {
            mode: ReplayGainMode::Track,
            track_gain_db: Some(6.0),
            album_gain_db: None,
            preamp_db: 0.0,
            peak: Some(0.8),
            maximum_scale: DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE,
        };
        let scale = apply_replay_gain(&mut samples, settings);

        assert_close(scale, 1.25, 0.000_001);
        assert!(scale < legacy_swift_linear(6.0, 0.0, DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE));
        assert!(scale < legacy_desktop_linear(ReplayGainMode::Track, 0.0, Some(6.0), None));
        assert_slices_close(&samples, &[1.0, -1.0, 0.5, -0.25], 0.000_001);
        assert!(samples.iter().all(|sample| sample.abs() <= 1.0));
    }

    #[test]
    fn replay_gain_peak_limiting_leaves_non_clipping_boosts_alone() {
        let settings = ReplayGainSettings {
            mode: ReplayGainMode::Track,
            track_gain_db: Some(6.0),
            album_gain_db: None,
            preamp_db: 0.0,
            peak: Some(0.4),
            maximum_scale: DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE,
        };

        assert_close(
            replay_gain_scale(settings),
            legacy_swift_linear(6.0, 0.0, DEFAULT_REPLAY_GAIN_MAXIMUM_SCALE),
            0.000_001,
        );
    }

    #[test]
    fn biquad_state_carries_across_buffer_boundaries() {
        let input = sine(48_000.0, 1_024, 1_000.0, 0.5);
        let mut one_buffer = input.clone();
        let mut split_buffers = input;

        let mut continuous = Biquad::peaking(48_000.0, 1_000.0, 6.0, 1.0);
        continuous.process(&mut one_buffer);

        let mut split = Biquad::peaking(48_000.0, 1_000.0, 6.0, 1.0);
        let (first, second) = split_buffers.split_at_mut(512);
        split.process(first);
        split.process(second);

        assert_slices_close(&split_buffers, &one_buffer, 0.0);
    }

    #[test]
    fn flat_equalizer_leaves_samples_unchanged() {
        let profile = EqualizerProfile::flat();
        let mut eq = Equalizer::from_profile(48_000.0, 2, &profile, true);
        let mut samples = [
            0.0_f32, 0.25, 0.5, -0.25, -0.5, 0.75, 0.125, -0.125, 0.9, -0.9,
        ];
        let before = samples;

        eq.process(&mut samples);

        assert_slices_close(&samples, &before, 0.000_001);
    }
}

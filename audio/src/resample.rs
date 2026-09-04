//! Changing the sample rate without changing the music.
//!
//! # Why this exists
//!
//! A device runs at the rate it runs at. An iPhone is 48 kHz, a lot of desktop
//! hardware is 44.1 kHz, and a CD rip is 44.1 kHz whatever it is played on.
//! Something has to reconcile those, and the options are: shift the pitch
//! (unacceptable, and it sounds like the recording is in the wrong key rather
//! than like a bug), refuse to play (which is what the sink did, and it turns
//! into silence with a moving progress bar), or resample.
//!
//! Resampling changes the samples, which makes it a decision, which puts it
//! here rather than in each platform's sink. A shell that resampled would be a
//! shell that decides how music sounds, and two of those drift.
//!
//! # How
//!
//! Rational resampling. 44.1 kHz to 48 kHz is exactly 147:160, so upsample by
//! 160, low-pass, and keep every 147th sample. Done naively that is enormous;
//! done as a polyphase filter it costs one dot product per output sample,
//! because every sample the upsampler inserts is a zero and multiplying by zero
//! is work not worth doing.
//!
//! The filter is a windowed sinc. The window is Kaiser with beta 8.6, which
//! puts the stopband near -90 dB - below the noise floor of any recording this
//! will ever be asked to play, so the resampling is inaudible rather than
//! merely acceptable. Linear interpolation would be far cheaper and is audible
//! on music as a dull high end, which is why it is not used here.

use std::f64::consts::PI;

/// Taps per polyphase branch.
///
/// The total filter is this times the upsampling factor, but only this many
/// multiply-adds happen per output sample. Thirty-two gives a transition band
/// narrow enough that nothing musical is touched.
const TAPS_PER_PHASE: usize = 32;

/// Converts interleaved `f32` from one sample rate to another.
pub struct Resampler {
    /// Polyphase branches: `phases[p]` are the taps for output phase `p`.
    phases: Vec<Vec<f32>>,
    /// Upsampling factor, after reducing the ratio.
    up: usize,
    /// Downsampling factor, after reducing the ratio.
    down: usize,
    channels: usize,
    /// The tail of previous input, per channel, so a block boundary is not a
    /// discontinuity. Without it every buffer edge would be a click.
    history: Vec<Vec<f32>>,
    /// Which polyphase branch the next output sample comes from.
    phase: usize,
    /// Input frames still to be consumed before the next output.
    input_cursor: usize,
}

impl Resampler {
    /// Build a resampler, or `None` when none is needed or possible.
    ///
    /// Returns `None` for equal rates, because passing audio through a filter
    /// that is meant to do nothing still costs quality - and "do nothing" is
    /// better expressed by having nothing in the path at all.
    pub fn new(input_rate: u32, output_rate: u32, channels: usize) -> Option<Self> {
        if input_rate == 0 || output_rate == 0 || channels == 0 {
            return None;
        }
        if input_rate == output_rate {
            return None;
        }

        let divisor = gcd(input_rate as usize, output_rate as usize);
        let up = output_rate as usize / divisor;
        let down = input_rate as usize / divisor;

        // The anti-alias cutoff is set by whichever rate is lower: upsampling
        // must not let images through, downsampling must not fold anything back.
        let cutoff = 0.5 / up.max(down) as f64;
        let taps = design(up, cutoff);

        let mut phases = vec![Vec::with_capacity(TAPS_PER_PHASE); up];
        for (index, tap) in taps.iter().enumerate() {
            // Gain of `up` compensates for the zeros the upsampler inserts,
            // which otherwise attenuate everything by exactly that factor.
            phases[index % up].push((tap * up as f64) as f32);
        }

        Some(Self {
            phases,
            up,
            down,
            channels,
            history: vec![vec![0.0; TAPS_PER_PHASE]; channels],
            phase: 0,
            input_cursor: 0,
        })
    }

    /// How many output frames `input_frames` will produce, approximately.
    ///
    /// Approximate because the exact count depends on the phase this call
    /// starts in; used only to size a buffer, never to decide correctness.
    pub fn output_estimate(&self, input_frames: usize) -> usize {
        input_frames * self.up / self.down + TAPS_PER_PHASE
    }

    /// Resample `input` into `output`, returning frames written.
    ///
    /// Both are interleaved. `output` must have room for
    /// [`Resampler::output_estimate`] frames.
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> usize {
        let channels = self.channels;
        if channels == 0 || input.is_empty() {
            return 0;
        }

        let input_frames = input.len() / channels;
        let capacity = output.len() / channels;
        let mut written = 0;

        for frame in 0..input_frames {
            // Push this frame into each channel's history, oldest out.
            for channel in 0..channels {
                let history = &mut self.history[channel];
                history.rotate_left(1);
                history[TAPS_PER_PHASE - 1] = input[frame * channels + channel];
            }

            // Emit every output sample whose position falls on this input
            // frame. Upsampling by `up` and keeping every `down`th means that
            // is usually one, sometimes zero, sometimes several.
            while self.input_cursor == 0 {
                if written >= capacity {
                    // Out of room. Stopping here loses nothing: the history is
                    // already advanced and the caller sees a short write.
                    return written;
                }

                let branch = &self.phases[self.phase];
                for channel in 0..channels {
                    let history = &self.history[channel];
                    let mut sum = 0.0f32;
                    for (tap, sample) in branch.iter().zip(history.iter().rev()) {
                        sum += tap * sample;
                    }
                    output[written * channels + channel] = sum;
                }
                written += 1;

                self.phase += self.down;
                self.input_cursor = self.phase / self.up;
                self.phase %= self.up;
            }
            self.input_cursor -= 1;
        }

        written
    }

    /// Forget the tail of previous audio.
    ///
    /// Called on a seek or a stop. Carrying filter history across unrelated
    /// audio puts a transient at the join, which is the same reason the
    /// equaliser is reset there.
    pub fn reset(&mut self) {
        for channel in self.history.iter_mut() {
            channel.fill(0.0);
        }
        self.phase = 0;
        self.input_cursor = 0;
    }
}

/// Windowed-sinc lowpass, `up * TAPS_PER_PHASE` taps long.
fn design(up: usize, cutoff: f64) -> Vec<f64> {
    let length = up * TAPS_PER_PHASE;
    let centre = (length - 1) as f64 / 2.0;
    // 8.6 puts the stopband near -90 dB, which is below the noise floor of any
    // recording this will be asked to play.
    let beta = 8.6;
    let denominator = bessel_i0(beta);

    (0..length)
        .map(|index| {
            let offset = index as f64 - centre;
            let sinc = if offset.abs() < 1e-9 {
                2.0 * cutoff
            } else {
                (2.0 * PI * cutoff * offset).sin() / (PI * offset)
            };
            let ratio = 2.0 * index as f64 / (length - 1) as f64 - 1.0;
            let window = bessel_i0(beta * (1.0 - ratio * ratio).max(0.0).sqrt()) / denominator;
            sinc * window
        })
        .collect()
}

/// Modified Bessel function of the first kind, order zero.
///
/// Series rather than a table: it is evaluated a few hundred times when a
/// resampler is built and never again.
fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0;
    let mut term = 1.0;
    let half = x / 2.0;
    for k in 1..64 {
        term *= (half / k as f64) * (half / k as f64);
        sum += term;
        if term < sum * 1e-16 {
            break;
        }
    }
    sum
}

fn gcd(a: usize, b: usize) -> usize {
    if b == 0 {
        a
    } else {
        gcd(b, a % b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Estimate a signal's frequency by counting rising zero crossings.
    ///
    /// Crude and sufficient: the property under test is that a tone comes out
    /// at the pitch it went in at, and a pitch error from a wrong ratio is
    /// enormous - 48/44.1 is nearly nine percent, which is more than a
    /// semitone.
    fn frequency(samples: &[f32], rate: f64) -> f64 {
        let mut crossings = 0;
        let mut first = None;
        let mut last = 0usize;
        for i in 1..samples.len() {
            if samples[i - 1] <= 0.0 && samples[i] > 0.0 {
                if first.is_none() {
                    first = Some(i);
                }
                last = i;
                crossings += 1;
            }
        }
        let first = first.unwrap_or(0);
        if crossings < 2 || last == first {
            return 0.0;
        }
        (crossings - 1) as f64 * rate / (last - first) as f64
    }

    fn tone(hz: f64, rate: u32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|n| ((2.0 * PI * hz * n as f64 / rate as f64).sin() * 0.5) as f32)
            .collect()
    }

    #[test]
    fn equal_rates_need_no_resampler_at_all() {
        assert!(Resampler::new(44_100, 44_100, 2).is_none());
    }

    #[test]
    fn the_ratio_is_reduced_to_its_simplest_form() {
        let r = Resampler::new(44_100, 48_000, 1).expect("44.1 to 48 is a real conversion");
        assert_eq!((r.up, r.down), (160, 147), "44100:48000 reduces to 147:160");
    }

    /// The one that matters. A tone must come out at the pitch it went in at;
    /// getting the ratio wrong shifts 44.1 to 48 by nearly nine percent, which
    /// is more than a semitone and unmistakable.
    #[test]
    fn a_tone_keeps_its_pitch_going_up_to_48k() {
        let input = tone(1_000.0, 44_100, 44_100);
        let mut resampler = Resampler::new(44_100, 48_000, 1).unwrap();
        let mut output = vec![0.0; resampler.output_estimate(input.len())];
        let frames = resampler.process(&input, &mut output);

        // Skip the filter's start-up, which is genuinely not the signal yet.
        let settled = &output[2_000..frames];
        let measured = frequency(settled, 48_000.0);
        assert!(
            (measured - 1_000.0).abs() < 15.0,
            "expected ~1000 Hz, measured {measured:.1} Hz"
        );
    }

    #[test]
    fn a_tone_keeps_its_pitch_coming_down_to_44k() {
        let input = tone(1_000.0, 48_000, 48_000);
        let mut resampler = Resampler::new(48_000, 44_100, 1).unwrap();
        let mut output = vec![0.0; resampler.output_estimate(input.len())];
        let frames = resampler.process(&input, &mut output);

        let settled = &output[2_000..frames];
        let measured = frequency(settled, 44_100.0);
        assert!(
            (measured - 1_000.0).abs() < 15.0,
            "expected ~1000 Hz, measured {measured:.1} Hz"
        );
    }

    /// Length is how a wrong ratio shows up as a track that runs long or short.
    #[test]
    fn one_second_in_is_one_second_out() {
        let input = tone(440.0, 44_100, 44_100);
        let mut resampler = Resampler::new(44_100, 48_000, 1).unwrap();
        let mut output = vec![0.0; resampler.output_estimate(input.len())];
        let frames = resampler.process(&input, &mut output);

        let expected = 48_000isize;
        assert!(
            (frames as isize - expected).abs() < 64,
            "expected ~{expected} frames, produced {frames}"
        );
    }

    #[test]
    fn stereo_channels_do_not_bleed_into_each_other() {
        // Left carries a tone, right is silent. Any leak is a bug in the
        // per-channel history, which is easy to write and hard to hear.
        let left = tone(1_000.0, 44_100, 8_820);
        let mut input = Vec::with_capacity(left.len() * 2);
        for sample in &left {
            input.push(*sample);
            input.push(0.0);
        }

        let mut resampler = Resampler::new(44_100, 48_000, 2).unwrap();
        let mut output = vec![0.0; resampler.output_estimate(left.len()) * 2];
        let frames = resampler.process(&input, &mut output);

        let right_peak = (0..frames)
            .map(|f| output[f * 2 + 1].abs())
            .fold(0.0f32, f32::max);
        assert!(
            right_peak < 0.001,
            "silence leaked into the right: {right_peak}"
        );
    }

    #[test]
    fn silence_stays_silent() {
        let input = vec![0.0f32; 4_410];
        let mut resampler = Resampler::new(44_100, 48_000, 1).unwrap();
        let mut output = vec![0.0; resampler.output_estimate(input.len())];
        let frames = resampler.process(&input, &mut output);

        assert!(frames > 0);
        assert!(
            output[..frames].iter().all(|s| s.abs() < 1e-6),
            "a filter that rings on silence is a filter with bad coefficients"
        );
    }

    /// Level has to survive. The upsampler inserts zeros, and forgetting to
    /// compensate attenuates everything by exactly the upsampling factor -
    /// which sounds like the volume dropped rather than like a filter bug.
    #[test]
    fn amplitude_is_preserved_rather_than_scaled_by_the_ratio() {
        let input = tone(440.0, 44_100, 22_050);
        let mut resampler = Resampler::new(44_100, 48_000, 1).unwrap();
        let mut output = vec![0.0; resampler.output_estimate(input.len())];
        let frames = resampler.process(&input, &mut output);

        let peak = output[2_000..frames]
            .iter()
            .fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(
            (peak - 0.5).abs() < 0.02,
            "expected a peak near 0.5, got {peak}"
        );
    }

    /// Feeding it in small blocks must give the same audio as one large block,
    /// or every buffer boundary is a click.
    #[test]
    fn block_boundaries_do_not_produce_a_discontinuity() {
        let input = tone(1_000.0, 44_100, 8_820);

        let mut whole = Resampler::new(44_100, 48_000, 1).unwrap();
        let mut expected = vec![0.0; whole.output_estimate(input.len())];
        let expected_frames = whole.process(&input, &mut expected);

        let mut piecewise = Resampler::new(44_100, 48_000, 1).unwrap();
        let mut actual = Vec::new();
        for chunk in input.chunks(101) {
            let mut block = vec![0.0; piecewise.output_estimate(chunk.len())];
            let frames = piecewise.process(chunk, &mut block);
            actual.extend_from_slice(&block[..frames]);
        }

        assert_eq!(actual.len(), expected_frames, "different frame counts");
        for (index, (a, b)) in actual
            .iter()
            .zip(expected[..expected_frames].iter())
            .enumerate()
        {
            assert!(
                (a - b).abs() < 1e-5,
                "sample {index} differs: {a} vs {b}; a block boundary changed the audio"
            );
        }
    }

    #[test]
    fn nothing_comes_out_as_nan_or_infinity() {
        let input = tone(15_000.0, 44_100, 4_410);
        let mut resampler = Resampler::new(44_100, 48_000, 1).unwrap();
        let mut output = vec![0.0; resampler.output_estimate(input.len())];
        let frames = resampler.process(&input, &mut output);

        assert!(output[..frames].iter().all(|s| s.is_finite()));
    }
}

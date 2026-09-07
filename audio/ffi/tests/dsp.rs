//! The DSP boundary, exercised the way a shell uses it.
//!
//! These matter more than they look: the whole reason this surface exists is
//! that a second implementation of the same filters is a divergence nothing
//! would catch. A shell that calls these and gets silence, or gets a buffer it
//! passed in unchanged, has the bug ADR-0015 is about.

use mozz_audio_ffi::{
    mozz_dsp_free, mozz_dsp_new, mozz_dsp_process, mozz_dsp_set_equalizer, mozz_dsp_set_gain_db,
};

const BANDS: usize = 10;

fn tone(frames: usize, channels: usize) -> Vec<f32> {
    (0..frames * channels)
        .map(|i| ((i as f32) * 0.05).sin() * 0.5)
        .collect()
}

#[test]
fn a_flat_disabled_bank_leaves_the_signal_alone() {
    let dsp = mozz_dsp_new(48_000, 2);
    assert!(!dsp.is_null());
    let mut samples = tone(64, 2);
    let original = samples.clone();

    assert!(unsafe { mozz_dsp_process(dsp, samples.as_mut_ptr(), 64) });

    // Bit-for-bit: a listener who has touched nothing must hear the file.
    assert_eq!(samples, original);
    unsafe { mozz_dsp_free(dsp) };
}

#[test]
fn a_boosted_band_changes_the_signal() {
    let dsp = mozz_dsp_new(48_000, 2);
    let mut gains = [0.0f64; BANDS];
    gains[4] = 9.0;
    assert!(unsafe { mozz_dsp_set_equalizer(dsp, gains.as_ptr(), BANDS, 0.0, true, 48_000) });

    let mut samples = tone(256, 2);
    let original = samples.clone();
    assert!(unsafe { mozz_dsp_process(dsp, samples.as_mut_ptr(), 256) });

    assert_ne!(samples, original, "an enabled band that does nothing is a dead control");
    unsafe { mozz_dsp_free(dsp) };
}

#[test]
fn levelling_attenuates_and_never_boosts() {
    let dsp = mozz_dsp_new(48_000, 1);
    assert!(unsafe { mozz_dsp_set_gain_db(dsp, -6.0) });
    let mut quiet = vec![1.0f32; 8];
    assert!(unsafe { mozz_dsp_process(dsp, quiet.as_mut_ptr(), 8) });
    assert!(quiet[0] < 0.51 && quiet[0] > 0.49, "-6 dB is about half: {}", quiet[0]);

    // A positive gain asks for headroom that is not there. Clipping is a worse
    // answer than not boosting, so unity is the ceiling.
    assert!(unsafe { mozz_dsp_set_gain_db(dsp, 12.0) });
    let mut loud = vec![1.0f32; 8];
    assert!(unsafe { mozz_dsp_process(dsp, loud.as_mut_ptr(), 8) });
    assert_eq!(loud[0], 1.0);
    unsafe { mozz_dsp_free(dsp) };
}

#[test]
fn a_band_count_that_disagrees_is_refused() {
    let dsp = mozz_dsp_new(48_000, 2);
    let gains = [0.0f64; 5];
    // Padding would hide a shell that disagrees with the core about the layout,
    // which is exactly the drift this surface exists to prevent.
    assert!(!unsafe { mozz_dsp_set_equalizer(dsp, gains.as_ptr(), 5, 0.0, true, 48_000) });
    unsafe { mozz_dsp_free(dsp) };
}

#[test]
fn nonsense_input_is_refused_rather_than_silencing_the_library() {
    assert!(mozz_dsp_new(0, 2).is_null());
    assert!(mozz_dsp_new(48_000, 0).is_null());

    let dsp = mozz_dsp_new(48_000, 2);
    assert!(!unsafe { mozz_dsp_set_gain_db(dsp, f64::NAN) });
    assert!(!unsafe { mozz_dsp_set_gain_db(dsp, f64::INFINITY) });
    // Still plays: a refused gain leaves the last good one in place.
    let mut samples = tone(16, 2);
    assert!(unsafe { mozz_dsp_process(dsp, samples.as_mut_ptr(), 16) });
    unsafe { mozz_dsp_free(dsp) };

    // Null is a no-op everywhere, so a shell that failed to allocate does not
    // then crash trying to tidy up.
    unsafe { mozz_dsp_free(std::ptr::null_mut()) };
    assert!(!unsafe { mozz_dsp_process(std::ptr::null_mut(), std::ptr::null_mut(), 0) });
}

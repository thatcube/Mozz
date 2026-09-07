//! Android's window onto the shared DSP.
//!
//! ExoPlayer already decodes, already speaks HLS — which Plex transcodes need —
//! and already owns the media session the car and the lock screen come from.
//! What it does not have is Mozz's equaliser. So Android keeps its player and
//! borrows the filters, rather than replacing a working pipeline to gain a
//! curve.
//!
//! The buffers arrive as 16-bit PCM, which is what `AudioProcessor` hands over
//! unless the whole sink is switched to float. Converting on this side rather
//! than in Kotlin keeps it to one JNI call per buffer instead of a per-sample
//! loop in a managed language.

use jni::objects::JClass;
use jni::sys::{jboolean, jbyteArray, jdouble, jdoubleArray, jint, jlong, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;
use mozz_audio::{Equalizer, EqualizerProfile, ISO_CENTRES_HZ};

/// A filter bank, its levelling gain, and a scratch buffer that is reused so a
/// callback running hundreds of times a second allocates nothing.
struct Dsp {
    equalizer: Equalizer,
    gain: f32,
    channels: usize,
    sample_rate: f64,
    scratch: Vec<f32>,
}

/// 16-bit PCM's full-scale value. Dividing by this and multiplying back is the
/// conversion; the asymmetry of two's complement is why the floor is -32768 and
/// the ceiling 32767 rather than a symmetric pair.
const SCALE: f32 = 32768.0;

#[no_mangle]
pub extern "system" fn Java_com_thatcube_mozz_playback_MozzDsp_nativeNew(
    _env: JNIEnv,
    _class: JClass,
    sample_rate: jint,
    channels: jint,
) -> jlong {
    if sample_rate <= 0 || channels <= 0 {
        return 0;
    }
    let channels = channels as usize;
    let sample_rate = f64::from(sample_rate);
    let dsp = Box::new(Dsp {
        equalizer: Equalizer::new(sample_rate, channels),
        gain: 1.0,
        channels,
        sample_rate,
        scratch: Vec::new(),
    });
    Box::into_raw(dsp) as jlong
}

#[no_mangle]
pub extern "system" fn Java_com_thatcube_mozz_playback_MozzDsp_nativeFree(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) {
    if handle == 0 {
        return;
    }
    // SAFETY: the Kotlin side frees exactly once and never uses the handle after.
    drop(unsafe { Box::from_raw(handle as *mut Dsp) });
}

#[no_mangle]
pub extern "system" fn Java_com_thatcube_mozz_playback_MozzDsp_nativeSetEqualizer(
    env: JNIEnv,
    _class: JClass,
    handle: jlong,
    gains_db: jdoubleArray,
    preamp_db: jdouble,
    enabled: jboolean,
) -> jboolean {
    let Some(dsp) = (unsafe { (handle as *mut Dsp).as_mut() }) else {
        return JNI_FALSE;
    };
    // SAFETY: `gains_db` is a Java double[] passed straight from Kotlin.
    let array = unsafe { jni::objects::JDoubleArray::from_raw(gains_db) };
    let Ok(length) = env.get_array_length(&array) else {
        return JNI_FALSE;
    };
    // Refused rather than padded: a shell that disagrees with the core about
    // how many bands there are has a bug worth finding.
    if length as usize != ISO_CENTRES_HZ.len() {
        return JNI_FALSE;
    }
    let mut gains = [0.0f64; ISO_CENTRES_HZ.len()];
    if env.get_double_array_region(&array, 0, &mut gains).is_err() {
        return JNI_FALSE;
    }
    let profile = EqualizerProfile::from_gains(gains, preamp_db);
    dsp.equalizer = Equalizer::from_profile(
        dsp.sample_rate,
        dsp.channels,
        &profile,
        enabled != JNI_FALSE,
    );
    JNI_TRUE
}

#[no_mangle]
pub extern "system" fn Java_com_thatcube_mozz_playback_MozzDsp_nativeSetGainDb(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
    gain_db: jdouble,
) -> jboolean {
    let Some(dsp) = (unsafe { (handle as *mut Dsp).as_mut() }) else {
        return JNI_FALSE;
    };
    // A gain that is not a number silences a library rather than colouring it,
    // so the last good one is kept.
    if !gain_db.is_finite() {
        return JNI_FALSE;
    }
    // Clamped at unity: a positive ReplayGain value asks for headroom that is
    // not there, and clipping is a worse answer than not boosting.
    dsp.gain = (10f64.powf(gain_db / 20.0)).clamp(0.0, 1.0) as f32;
    JNI_TRUE
}

/// Filter one buffer of interleaved 16-bit PCM in place.
///
/// Returns false when nothing was done, which the caller treats as "pass the
/// buffer through" rather than as an error: an equaliser that cannot run should
/// leave the music playing.
#[no_mangle]
pub extern "system" fn Java_com_thatcube_mozz_playback_MozzDsp_nativeProcess(
    env: JNIEnv,
    _class: JClass,
    handle: jlong,
    pcm: jbyteArray,
    length: jint,
) -> jboolean {
    let Some(dsp) = (unsafe { (handle as *mut Dsp).as_mut() }) else {
        return JNI_FALSE;
    };
    if length <= 0 {
        return JNI_TRUE;
    }
    let samples = (length as usize) / 2;
    if samples == 0 || samples % dsp.channels != 0 {
        // A partial frame would mean guessing the missing channels, which is a
        // decision this layer has no business making.
        return JNI_FALSE;
    }

    // SAFETY: `pcm` is a Java byte[] passed straight from Kotlin.
    let array = unsafe { jni::objects::JByteArray::from_raw(pcm) };
    let mut bytes = vec![0i8; length as usize];
    if env.get_byte_array_region(&array, 0, &mut bytes).is_err() {
        return JNI_FALSE;
    }

    dsp.scratch.clear();
    dsp.scratch.reserve(samples);
    for frame in bytes.chunks_exact(2) {
        // Little-endian, which is what ExoPlayer hands over and what every
        // Android device this runs on uses.
        let value = i16::from_le_bytes([frame[0] as u8, frame[1] as u8]);
        dsp.scratch.push(f32::from(value) / SCALE);
    }

    if dsp.gain != 1.0 {
        for sample in dsp.scratch.iter_mut() {
            *sample *= dsp.gain;
        }
    }
    dsp.equalizer.process(&mut dsp.scratch);

    for (index, sample) in dsp.scratch.iter().enumerate() {
        // Clamped before the cast: a boosted band can exceed full scale, and an
        // out-of-range float cast wraps rather than saturating, which is heard
        // as a crack rather than as clipping.
        let clamped = (sample * SCALE).clamp(-SCALE, SCALE - 1.0) as i16;
        let [low, high] = clamped.to_le_bytes();
        bytes[index * 2] = low as i8;
        bytes[index * 2 + 1] = high as i8;
    }

    if env.set_byte_array_region(&array, 0, &bytes).is_err() {
        return JNI_FALSE;
    }
    JNI_TRUE
}

//! A single-producer, single-consumer ring of interleaved `f32` samples, with
//! the track boundaries written alongside the audio.
//!
//! # Why the boundaries live in here
//!
//! Gapless playback means the last sample of one track and the first sample of
//! the next are adjacent, with nothing between them. That is easy to produce
//! and surprisingly hard to *describe*: the moment the music changes track is
//! no longer a moment when anything happens to the audio, so there is nothing
//! for a player to observe. Ask "what is playing now" and the honest answer
//! depends on which sample the speaker has reached, not on any event.
//!
//! Attaching a timer to it does not work. The decoder runs ahead of the
//! speaker by however much buffer it has managed to fill, so a track that has
//! finished decoding is still minutes from being heard. Any clock started when
//! decoding ends reports the change early, and by a margin that changes with
//! buffer pressure - exactly the kind of bug that only appears on a slow
//! network.
//!
//! So a boundary is not an event. It is a label on a sample position, carried
//! by the buffer and reported when the consumer actually reaches it. The
//! consumer here is the audio callback, and what it reports is what came out
//! of the speaker.
//!
//! # The real-time contract
//!
//! [`Consumer::read`] runs on the audio callback: a thread with a hard
//! deadline, where the cost of missing it is an audible click rather than a
//! slow frame. It must not allocate, lock, block, or panic - and none of those
//! are things a reviewer can check by reading.
//!
//! Some of that is enforced rather than promised. The crate sets
//! `#![forbid(unsafe_code)]`, which ruled out the usual ring buffer built on
//! `UnsafeCell` and a raw slice. Samples are therefore stored as `AtomicU32`
//! holding the bit pattern of each `f32`, moved with relaxed loads and stores.
//! That costs a loop where a `memcpy` would otherwise do, which for a few
//! hundred frames per callback is the same work a `memcpy` performs anyway,
//! and it buys a data-race freedom argument the compiler checks instead of one
//! a comment asserts.
//!
//! The buffer starves rather than blocking. A consumer that catches up with
//! the producer is told how many samples it really got and fills the rest with
//! silence, because a callback that waits for data produces a much worse sound
//! than one that admits it has none.

use core::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

/// How many track boundaries may be pending at once.
///
/// A boundary is consumed as the audio passes it, so this only has to cover how
/// many tracks can sit in the buffer at the same time. Even a long buffer of
/// very short tracks stays far below this.
const MAX_PENDING_BOUNDARIES: usize = 64;

/// A point where one track gives way to the next, and what it gives way to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Boundary {
    /// Absolute sample-frame index, counted from the first frame ever written.
    ///
    /// Absolute rather than relative to the buffer, because a position that
    /// means something only until the ring wraps is a position that will be
    /// read after it wraps.
    pub frame: u64,
    /// Opaque identifier of the track starting at `frame`, assigned by the
    /// caller. The ring never interprets it.
    pub track: u64,
}

/// What a read actually produced.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct ReadOutcome {
    /// Frames of real audio written to the output. Any remainder was silence.
    pub frames: usize,
    /// A boundary crossed during this read, if one was.
    ///
    /// One rather than many: two boundaries inside a single callback would mean
    /// a track shorter than one buffer period, a few milliseconds. Reporting
    /// the last is the honest answer to "what is playing now" even then.
    pub boundary: Option<Boundary>,
    /// Absolute frame index just past the last real frame of this read.
    ///
    /// Absolute so a consumer can say how far into a track it is by
    /// subtracting the track's boundary frame, which is exact. Deriving it by
    /// counting reads instead drifts, because a starved read advances the
    /// clock without advancing the audio.
    pub end_frame: u64,
    /// True when the ring ran dry and silence was substituted.
    ///
    /// Distinct from `frames < requested` so that the ordinary end of a queue
    /// and a decoder failing to keep up are not the same condition. One is
    /// expected; the other is a fault worth surfacing.
    pub starved: bool,
}

/// A `Boundary` published without a lock.
///
/// Two atomics rather than one wider value: the pair is only read after an
/// `Acquire` on the queue index that publishes it, so the index is what orders
/// them and the pair itself need not be read atomically.
struct BoundarySlot {
    frame: AtomicU64,
    track: AtomicU64,
}

impl BoundarySlot {
    fn new() -> Self {
        Self {
            frame: AtomicU64::new(0),
            track: AtomicU64::new(0),
        }
    }
}

struct Shared {
    /// Interleaved samples, each held as the bit pattern of an `f32`.
    ///
    /// Atomics rather than plain floats because the producer and consumer share
    /// this allocation, and without `unsafe` there is no other way to write to
    /// it through a shared reference. Relaxed ordering is enough: the `written`
    /// and `read` indices carry all the happens-before this needs, and a sample
    /// is only ever touched by one side at a time as a result.
    buffer: Vec<AtomicU32>,
    channels: usize,
    /// Frames written and read, counted absolutely and never reset.
    ///
    /// Absolute so that "how full is it" is a subtraction rather than a
    /// comparison with a wrap case - the wrap case being where ring buffers are
    /// traditionally wrong.
    written: AtomicUsize,
    read: AtomicUsize,
    boundaries: Vec<BoundarySlot>,
    boundary_written: AtomicUsize,
    boundary_read: AtomicUsize,
}

impl Shared {
    fn capacity_frames(&self) -> usize {
        self.buffer.len() / self.channels
    }
}

/// Create a connected producer and consumer.
///
/// `capacity_frames` is rounded up to at least one frame.
///
/// # Panics
///
/// Panics if `channels` is zero. That is an argument error at construction, not
/// a condition that can arise while running, so it cannot fire on the audio
/// thread.
pub fn ring(capacity_frames: usize, channels: usize) -> (Producer, Consumer) {
    assert!(channels > 0, "a ring needs at least one channel");
    let frames = capacity_frames.max(1);

    let mut buffer = Vec::with_capacity(frames * channels);
    for _ in 0..frames * channels {
        buffer.push(AtomicU32::new(0));
    }

    let mut boundaries = Vec::with_capacity(MAX_PENDING_BOUNDARIES);
    for _ in 0..MAX_PENDING_BOUNDARIES {
        boundaries.push(BoundarySlot::new());
    }

    let shared = Arc::new(Shared {
        buffer,
        channels,
        written: AtomicUsize::new(0),
        read: AtomicUsize::new(0),
        boundaries,
        boundary_written: AtomicUsize::new(0),
        boundary_read: AtomicUsize::new(0),
    });

    (
        Producer {
            shared: Arc::clone(&shared),
        },
        Consumer { shared },
    )
}

/// The writing half. Lives on the decode thread.
pub struct Producer {
    shared: Arc<Shared>,
}

impl Producer {
    /// Frames that can be written before the ring is full.
    pub fn free_frames(&self) -> usize {
        let written = self.shared.written.load(Ordering::Relaxed);
        let read = self.shared.read.load(Ordering::Acquire);
        self.shared.capacity_frames() - (written - read)
    }

    /// Frames written but not yet read, i.e. still waiting to be heard.
    ///
    /// The difference between this and zero is the difference between "the
    /// decoder has finished" and "the music has finished", which are separated
    /// by the whole buffer.
    pub fn queued_frames(&self) -> usize {
        let written = self.shared.written.load(Ordering::Relaxed);
        let read = self.shared.read.load(Ordering::Acquire);
        written - read
    }

    /// Absolute index of the next frame to be written.
    pub fn next_frame(&self) -> u64 {
        self.shared.written.load(Ordering::Relaxed) as u64
    }

    /// Absolute index of the next frame to be read, i.e. how much has been heard.
    ///
    /// Monotonic, and deliberately untouched by [`reset`](Self::reset): a seek
    /// throws away audio that was queued, not audio that was played. A caller
    /// re-basing a position after a seek needs this to know where the audio it
    /// is about to write will land.
    pub fn frames_read(&self) -> u64 {
        self.shared.read.load(Ordering::Acquire) as u64
    }

    /// Append interleaved samples, returning how many frames were taken.
    ///
    /// A short write means the ring is full, which is how a decoder learns to
    /// stop decoding. It is not an error and loses nothing: the untaken
    /// remainder is still the caller's to offer again.
    pub fn write(&mut self, interleaved: &[f32]) -> usize {
        let channels = self.shared.channels;
        debug_assert_eq!(
            interleaved.len() % channels,
            0,
            "a partial frame cannot be written"
        );

        let offered = interleaved.len() / channels;
        let take = offered.min(self.free_frames());
        if take == 0 {
            return 0;
        }

        let capacity = self.shared.capacity_frames();
        let written = self.shared.written.load(Ordering::Relaxed);

        for frame in 0..take {
            let slot = ((written + frame) % capacity) * channels;
            let src = frame * channels;
            for channel in 0..channels {
                self.shared.buffer[slot + channel]
                    .store(interleaved[src + channel].to_bits(), Ordering::Relaxed);
            }
        }

        // Release so the consumer's Acquire on this index sees those samples.
        self.shared.written.store(written + take, Ordering::Release);
        take
    }

    /// Record that a new track begins at the next frame to be written.
    ///
    /// Returns false when [`MAX_PENDING_BOUNDARIES`] are already queued, which
    /// means the buffer is holding that many tracks at once. The caller should
    /// stop queueing rather than treat it as fatal.
    pub fn mark_boundary(&mut self, track: u64) -> bool {
        let frame = self.next_frame();
        let write = self.shared.boundary_written.load(Ordering::Relaxed);
        let read = self.shared.boundary_read.load(Ordering::Acquire);
        if write - read >= MAX_PENDING_BOUNDARIES {
            return false;
        }

        let slot = &self.shared.boundaries[write % MAX_PENDING_BOUNDARIES];
        slot.frame.store(frame, Ordering::Relaxed);
        slot.track.store(track, Ordering::Relaxed);
        self.shared
            .boundary_written
            .store(write + 1, Ordering::Release);
        true
    }

    /// Discard everything queued and start again at the current read position.
    ///
    /// This is a seek or a skip: audio already handed to the speaker cannot be
    /// recalled, but nothing after it should still be heard.
    pub fn reset(&mut self) {
        let read = self.shared.read.load(Ordering::Acquire);
        self.shared.written.store(read, Ordering::Release);
        let boundary_read = self.shared.boundary_read.load(Ordering::Acquire);
        self.shared
            .boundary_written
            .store(boundary_read, Ordering::Release);
    }
}

/// The reading half. Lives on the audio callback.
pub struct Consumer {
    shared: Arc<Shared>,
}

impl Consumer {
    /// Frames available to read right now.
    pub fn available_frames(&self) -> usize {
        let written = self.shared.written.load(Ordering::Acquire);
        let read = self.shared.read.load(Ordering::Relaxed);
        written - read
    }

    /// Fill `out` with interleaved samples, padding with silence if short.
    ///
    /// Real-time safe: no allocation, no locking, no blocking, and no reachable
    /// panic. Everything it touches was allocated when the ring was built.
    pub fn read(&mut self, out: &mut [f32]) -> ReadOutcome {
        let channels = self.shared.channels;
        let requested = out.len() / channels;
        if requested == 0 {
            return ReadOutcome::default();
        }

        let written = self.shared.written.load(Ordering::Acquire);
        let read = self.shared.read.load(Ordering::Relaxed);
        let take = requested.min(written - read);

        let capacity = self.shared.capacity_frames();
        for frame in 0..take {
            let slot = ((read + frame) % capacity) * channels;
            let dst = frame * channels;
            for channel in 0..channels {
                out[dst + channel] =
                    f32::from_bits(self.shared.buffer[slot + channel].load(Ordering::Relaxed));
            }
        }

        if take > 0 {
            // Release so the producer's Acquire sees these frames as reusable.
            self.shared.read.store(read + take, Ordering::Release);
        }

        // Silence rather than stale audio. Leaving the tail untouched replays
        // whatever the previous callback put there, which buzzes at the buffer
        // period - far more noticeable than a gap.
        for sample in out[take * channels..].iter_mut() {
            *sample = 0.0;
        }

        let boundary = self.take_boundary_up_to((read + take) as u64);

        ReadOutcome {
            frames: take,
            end_frame: (read + take) as u64,
            boundary,
            starved: take < requested,
        }
    }

    /// Claim the newest boundary strictly before `end`, discarding older ones.
    ///
    /// `end` is exclusive because a read covering frames `[start, end)` has
    /// reached `end - 1`, not `end`. A boundary sitting exactly at `end` labels
    /// the first frame of the *next* read, and reporting it here would announce
    /// every track change one buffer early - a fifth of a second at typical
    /// sizes, and enough to make Now Playing visibly disagree with the speaker.
    fn take_boundary_up_to(&mut self, end: u64) -> Option<Boundary> {
        let mut found = None;
        loop {
            let read = self.shared.boundary_read.load(Ordering::Relaxed);
            let written = self.shared.boundary_written.load(Ordering::Acquire);
            if read == written {
                break;
            }

            let slot = &self.shared.boundaries[read % MAX_PENDING_BOUNDARIES];
            let at = slot.frame.load(Ordering::Relaxed);
            if at >= end {
                break;
            }

            found = Some(Boundary {
                frame: at,
                track: slot.track.load(Ordering::Relaxed),
            });
            self.shared.boundary_read.store(read + 1, Ordering::Release);
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frames(values: &[f32]) -> Vec<f32> {
        values.to_vec()
    }

    #[test]
    fn a_read_returns_what_was_written() {
        let (mut tx, mut rx) = ring(8, 1);
        assert_eq!(tx.write(&frames(&[1.0, 2.0, 3.0])), 3);

        let mut out = [0.0; 3];
        let outcome = rx.read(&mut out);

        assert_eq!(outcome.frames, 3);
        assert!(!outcome.starved);
        assert_eq!(out, [1.0, 2.0, 3.0]);
    }

    #[test]
    fn channels_are_kept_interleaved() {
        let (mut tx, mut rx) = ring(4, 2);
        tx.write(&frames(&[-1.0, 1.0, -0.5, 0.5]));

        let mut out = [0.0; 4];
        rx.read(&mut out);

        assert_eq!(out, [-1.0, 1.0, -0.5, 0.5]);
    }

    /// The wrap is where ring buffers are traditionally wrong, so write and
    /// read across it repeatedly rather than once.
    #[test]
    fn samples_survive_wrapping_many_times() {
        let (mut tx, mut rx) = ring(4, 1);
        let mut expected = 0.0f32;

        for _ in 0..50 {
            let batch = [expected, expected + 1.0, expected + 2.0];
            assert_eq!(tx.write(&batch), 3);

            let mut out = [0.0; 3];
            let outcome = rx.read(&mut out);
            assert_eq!(outcome.frames, 3);
            assert_eq!(out, batch);
            expected += 3.0;
        }
    }

    #[test]
    fn a_full_ring_takes_no_more_and_loses_nothing() {
        let (mut tx, mut rx) = ring(2, 1);
        assert_eq!(tx.write(&frames(&[1.0, 2.0, 3.0, 4.0])), 2);
        assert_eq!(tx.free_frames(), 0);
        assert_eq!(tx.write(&frames(&[9.0])), 0);

        let mut out = [0.0; 2];
        rx.read(&mut out);
        assert_eq!(
            out,
            [1.0, 2.0],
            "the frames it refused were not the ones it kept"
        );
    }

    /// A callback that gets less than it asked for must still hand the device a
    /// full buffer, and the remainder has to be silence rather than whatever
    /// the previous callback left there - stale audio buzzes at the buffer
    /// period, which is far worse than a gap.
    #[test]
    fn a_short_read_is_padded_with_silence_and_says_it_starved() {
        let (mut tx, mut rx) = ring(8, 1);
        tx.write(&frames(&[1.0, 2.0]));

        let mut out = [99.0; 4];
        let outcome = rx.read(&mut out);

        assert_eq!(outcome.frames, 2);
        assert!(outcome.starved);
        assert_eq!(out, [1.0, 2.0, 0.0, 0.0]);
    }

    #[test]
    fn an_empty_ring_reads_as_silence() {
        let (_tx, mut rx) = ring(4, 2);
        let mut out = [7.0; 4];
        let outcome = rx.read(&mut out);

        assert_eq!(outcome.frames, 0);
        assert!(outcome.starved);
        assert_eq!(out, [0.0; 4]);
    }

    /// The whole point of the design: the boundary is reported when the audio
    /// reaches it, not when the decoder queued it.
    #[test]
    fn a_boundary_is_reported_only_when_the_audio_reaches_it() {
        let (mut tx, mut rx) = ring(16, 1);
        tx.write(&frames(&[1.0, 2.0, 3.0, 4.0]));
        tx.mark_boundary(77);
        tx.write(&frames(&[5.0, 6.0]));

        // The boundary sits at frame 4 and this read stops at frame 2.
        let mut out = [0.0; 2];
        assert_eq!(
            rx.read(&mut out).boundary,
            None,
            "reported before it was heard"
        );

        // Now cross it.
        let mut out = [0.0; 4];
        let outcome = rx.read(&mut out);
        assert_eq!(
            outcome.boundary,
            Some(Boundary {
                frame: 4,
                track: 77
            })
        );
    }

    #[test]
    fn a_boundary_is_reported_exactly_once() {
        let (mut tx, mut rx) = ring(16, 1);
        tx.write(&frames(&[1.0, 2.0]));
        tx.mark_boundary(5);
        tx.write(&frames(&[3.0, 4.0]));

        let mut out = [0.0; 4];
        assert!(rx.read(&mut out).boundary.is_some());

        tx.write(&frames(&[5.0]));
        let mut out = [0.0; 1];
        assert_eq!(rx.read(&mut out).boundary, None, "reported a second time");
    }

    /// A track shorter than one callback means two boundaries land in the same
    /// read. "What is playing now" is the later one; the earlier is already
    /// over by the time anyone could be told.
    #[test]
    fn several_boundaries_in_one_read_report_the_last() {
        let (mut tx, mut rx) = ring(16, 1);
        tx.mark_boundary(1);
        tx.write(&frames(&[1.0]));
        tx.mark_boundary(2);
        tx.write(&frames(&[2.0]));
        tx.mark_boundary(3);
        tx.write(&frames(&[3.0]));

        let mut out = [0.0; 3];
        let outcome = rx.read(&mut out);
        assert_eq!(outcome.boundary.map(|b| b.track), Some(3));
    }

    /// Gapless means the samples either side of a boundary are adjacent. If a
    /// boundary ever inserted so much as one frame of silence it would be
    /// audible, and the label would have become an event after all.
    #[test]
    fn a_boundary_does_not_disturb_the_samples() {
        let (mut tx, mut rx) = ring(16, 1);
        tx.write(&frames(&[1.0, 2.0]));
        tx.mark_boundary(9);
        tx.write(&frames(&[3.0, 4.0]));

        let mut out = [0.0; 4];
        rx.read(&mut out);
        assert_eq!(out, [1.0, 2.0, 3.0, 4.0]);
    }

    #[test]
    fn a_reset_drops_queued_audio_and_its_boundaries() {
        let (mut tx, mut rx) = ring(16, 1);
        tx.write(&frames(&[1.0, 2.0, 3.0, 4.0]));
        tx.mark_boundary(1);
        tx.reset();

        let mut out = [5.0; 2];
        let outcome = rx.read(&mut out);
        assert_eq!(outcome.frames, 0);
        assert_eq!(outcome.boundary, None);
        assert_eq!(out, [0.0, 0.0]);

        // And it is usable again afterwards.
        tx.write(&frames(&[8.0]));
        let mut out = [0.0; 1];
        assert_eq!(rx.read(&mut out).frames, 1);
        assert_eq!(out, [8.0]);
    }

    #[test]
    fn boundaries_stop_being_accepted_rather_than_overwriting_older_ones() {
        let (mut tx, _rx) = ring(4096, 1);
        for track in 0..MAX_PENDING_BOUNDARIES as u64 {
            assert!(tx.mark_boundary(track), "rejected boundary {track} early");
            tx.write(&frames(&[0.0]));
        }
        assert!(!tx.mark_boundary(9999), "accepted more than it can hold");
    }

    /// The producer and consumer really do run on different threads, so drive
    /// them from two and check every sample arrives in order.
    #[test]
    fn a_stream_crosses_threads_intact() {
        use std::thread;

        let (mut tx, mut rx) = ring(64, 1);
        const TOTAL: usize = 20_000;

        let writer = thread::spawn(move || {
            let mut sent = 0usize;
            while sent < TOTAL {
                let batch: Vec<f32> = (sent..(sent + 16).min(TOTAL)).map(|v| v as f32).collect();
                let mut offset = 0;
                while offset < batch.len() {
                    let took = tx.write(&batch[offset..]);
                    if took == 0 {
                        thread::yield_now();
                        continue;
                    }
                    offset += took;
                }
                sent += batch.len();
            }
        });

        let mut expected = 0usize;
        let mut out = [0.0f32; 32];
        while expected < TOTAL {
            let outcome = rx.read(&mut out);
            for &value in out.iter().take(outcome.frames) {
                assert_eq!(value, expected as f32, "sample {expected} arrived wrong");
                expected += 1;
            }
            if outcome.frames == 0 {
                std::thread::yield_now();
            }
        }

        writer.join().expect("writer panicked");
        assert_eq!(expected, TOTAL);
    }
}

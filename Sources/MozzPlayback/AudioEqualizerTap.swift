import Foundation
import AVFoundation
import AudioToolbox
import MediaToolbox
import os
import MozzCore

// MARK: - Equalizer DSP (MTAudioProcessingTap + inline biquad filters)
//
// This applies ``EqualizerSettings`` to the app's own decoded audio inside an
// `MTAudioProcessingTap` attached to the SAME per-item
// `AVMutableAudioMixInputParameters` that carries ReplayGain volume. One tap per
// `AVPlayerItem`, so `AVQueuePlayer`'s gapless pre-roll is preserved.
//
// The DSP is a cascade of ten peaking biquad filters per channel, run directly on
// the tap's PCM buffers. We deliberately do NOT host an Audio Unit here: driving
// `kAudioUnitSubType_NBandEQ` via `AudioUnitRender` / `AudioUnitSetParameter` from
// inside the tap callback proved unreliable for live band changes and could stall
// playback. Reading plain biquad coefficients in the sample loop makes live slider
// moves take effect immediately with no reload and no glitch.
//
// The tap only installs where an `AVAssetTrack` exists — local downloads and
// direct-play / progressive remote audio. It silently no-ops on HLS (no
// accessible track), exactly the boundary ReplayGain already has.

/// The coordinator the app and `PlaybackEngine` talk to. Owns the authoritative
/// ``EqualizerSettings`` and the master on/off, mints a tap per player item, and
/// broadcasts live changes to every currently-attached tap.
@MainActor
public final class EqualizerProcessor {
    /// The master switch. Changing it requires the engine to rebuild loaded items
    /// (so all queued items are homogeneously tapped/untapped — a hard requirement
    /// for gapless), so the engine owns the setter side-effect; this is just state.
    public var isEnabled: Bool

    /// The current curve. `apply(_:)` mutates this and pushes to live taps.
    public private(set) var settings: EqualizerSettings

    private var contexts: [WeakContext] = []
    private struct WeakContext { weak var value: EqualizerTapContext? }

    public init(settings: EqualizerSettings = .flat, enabled: Bool = false) {
        self.settings = settings
        self.isEnabled = enabled
    }

    /// Build an EQ tap seeded with the current settings and attach it to `params`.
    /// If the tap can't be created the item simply plays unequalized.
    func attach(to params: AVMutableAudioMixInputParameters) {
        let context = EqualizerTapContext(settings: settings)
        guard let tap = makeEqualizerTap(context: context) else { return }
        params.audioTapProcessor = tap
        contexts.removeAll { $0.value == nil }
        contexts.append(WeakContext(value: context))
    }

    /// Replace the curve and push it to every live tap — a glitch-free live update
    /// (no reload, no gap).
    public func apply(_ newSettings: EqualizerSettings) {
        settings = newSettings
        contexts.removeAll { $0.value == nil }
        for box in contexts { box.value?.update(settings: newSettings) }
    }
}

// MARK: - Per-item tap context

/// Owns the per-channel filter cascade for a single tapped `AVPlayerItem` and
/// bridges the main thread's live curve changes to the render thread.
///
/// Threading: `prepare` / `unprepare` / `process` are delivered on the same serial
/// audio-processing thread. The only cross-thread contact is `update(settings:)`
/// from the main thread; it stores freshly-computed coefficients under `lock` and
/// flags them, and `process` picks them up with a non-blocking `lockIfAvailable`
/// (so the render thread never blocks on the UI thread).
final class EqualizerTapContext {
    private let lock = OSAllocatedUnfairLock()

    // Guarded by `lock`: the latest coefficients + preamp the UI produced, and a
    // flag telling the render thread to adopt them. Coefficients are computed on
    // the main thread (allocation there is fine); the render thread only copies.
    private var pendingCoeffs: [BiquadCoefficients]?
    private var pendingPreamp: Float = 1
    private var pendingDirty = false
    private var latestSettings: EqualizerSettings

    // Audio-thread-only state.
    private var sampleRate: Double = 0
    private var channelCount = 0
    private var isInterleaved = false
    private var filters: [[Biquad]] = []          // [channel][band]
    private var preamp: Float = 1
    private var prepared = false

    init(settings: EqualizerSettings) {
        self.latestSettings = settings
    }

    // MARK: Main thread

    /// Compute the new coefficients (needs the sample rate, known once prepared)
    /// and hand them to the render thread. Before `prepare` we just stash the
    /// settings; `prepare` builds the initial cascade from them.
    func update(settings: EqualizerSettings) {
        lock.lock()
        latestSettings = settings
        if sampleRate > 0 {
            pendingCoeffs = settings.biquadCoefficients(sampleRate: sampleRate)
            pendingPreamp = Float(settings.preampScalar)
            pendingDirty = true
        }
        lock.unlock()
    }

    // MARK: Audio thread — tap lifecycle

    func prepare(format: AudioStreamBasicDescription) {
        let rate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let interleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        // Build the initial cascade from whatever the UI last set. `sampleRate` is
        // the one field also read cross-thread (by `update` on the main thread), so
        // set it here under the lock; the remaining fields are audio-thread-only.
        lock.lock()
        let settings = latestSettings
        pendingDirty = false
        pendingCoeffs = nil
        sampleRate = rate
        lock.unlock()

        let coeffs = settings.biquadCoefficients(sampleRate: rate)
        let pre = Float(settings.preampScalar)
        var cascade: [[Biquad]] = []
        cascade.reserveCapacity(channels)
        for _ in 0..<channels {
            cascade.append(coeffs.map { Biquad(coefficients: $0) })
        }

        channelCount = channels
        isInterleaved = interleaved
        filters = cascade
        preamp = pre
        prepared = true
    }

    func unprepare() {
        prepared = false
        filters = []
    }

    // MARK: Audio thread — render

    func process(tap: MTAudioProcessingTap,
                 numberFrames: CMItemCount,
                 flags: MTAudioProcessingTapFlags,
                 bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                 numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                 flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
        // Always fetch the source; on failure there's nothing to process.
        let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                        flagsOut, nil, numberFramesOut)
        guard status == noErr else { return }
        guard prepared, channelCount > 0, !filters.isEmpty else { return }

        // Adopt any pending curve change without blocking the render thread.
        if lock.lockIfAvailable() {
            if pendingDirty, let coeffs = pendingCoeffs {
                for ch in 0..<filters.count {
                    for band in 0..<filters[ch].count where band < coeffs.count {
                        filters[ch][band].coefficients = coeffs[band]
                    }
                }
                preamp = pendingPreamp
                pendingDirty = false
            }
            lock.unlock()
        }

        // A seek restarts the stream: clear filter memory so it doesn't click.
        if (flagsOut.pointee & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_StartOfStream)) != 0 {
            for ch in 0..<filters.count {
                for band in 0..<filters[ch].count { filters[ch][band].reset() }
            }
        }

        let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
        let gain = preamp

        if isInterleaved {
            guard let buffer = abl.first, let raw = buffer.mData else { return }
            let ch = max(Int(buffer.mNumberChannels), 1)
            let bytesPerFrame = MemoryLayout<Float>.size * ch
            guard bytesPerFrame > 0 else { return }
            let frames = Int(buffer.mDataByteSize) / bytesPerFrame
            let samples = raw.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                for c in 0..<min(ch, filters.count) {
                    let i = f * ch + c
                    samples[i] = processSample(samples[i], channel: c) * gain
                }
            }
        } else {
            for c in 0..<min(abl.count, filters.count) {
                guard let raw = abl[c].mData else { continue }
                let n = Int(abl[c].mDataByteSize) / MemoryLayout<Float>.size
                let samples = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<n {
                    samples[i] = processSample(samples[i], channel: c) * gain
                }
            }
        }
    }

    /// Cascade one sample through the channel's ten peaking filters.
    @inline(__always)
    private func processSample(_ input: Float, channel: Int) -> Float {
        var x = input
        let count = filters[channel].count
        for band in 0..<count {
            x = filters[channel][band].process(x)
        }
        return x
    }
}

// MARK: - C callbacks

/// Create an `MTAudioProcessingTap` bound to `context`. The tap retains the
/// context (balanced by `release` in the finalize callback).
private func makeEqualizerTap(context: EqualizerTapContext) -> MTAudioProcessingTap? {
    let rawContext = Unmanaged.passRetained(context).toOpaque()
    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: rawContext,
        init: tapInit,
        finalize: tapFinalize,
        prepare: tapPrepare,
        unprepare: tapUnprepare,
        process: tapProcess)

    var tap: MTAudioProcessingTap?
    // PreEffects: the tap sees audio before the mix's volume ramp, so EQ shapes
    // the full-scale signal and ReplayGain attenuates the equalized result.
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                            kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
    guard status == noErr, let tap else {
        Unmanaged<EqualizerTapContext>.fromOpaque(rawContext).release()
        return nil
    }
    return tap
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let context = Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.prepare(format: format.pointee)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    let context = Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.unprepare()
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
    let context = Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.process(tap: tap, numberFrames: numberFrames, flags: flags,
                    bufferListInOut: bufferListInOut, numberFramesOut: numberFramesOut, flagsOut: flagsOut)
}

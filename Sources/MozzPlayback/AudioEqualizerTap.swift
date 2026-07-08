import Foundation
import AVFoundation
import AudioToolbox
import MediaToolbox
import os
import MozzCore

// MARK: - Equalizer DSP (MTAudioProcessingTap + kAudioUnitSubType_NBandEQ)
//
// This applies ``EqualizerSettings`` to the app's own decoded audio by hosting
// Apple's 10-band EQ Audio Unit inside an `MTAudioProcessingTap` attached to the
// SAME per-item `AVMutableAudioMixInputParameters` that carries ReplayGain volume.
// One tap per `AVPlayerItem`, so `AVQueuePlayer`'s gapless pre-roll is preserved.
//
// The tap only installs where an `AVAssetTrack` exists — local downloads and
// direct-play / progressive remote audio. It silently no-ops on HLS (no
// accessible track), exactly the boundary ReplayGain already has.
//
// Design constraints (all load-bearing; verified against Apple docs + production
// references): the mix must be attached BEFORE the item is enqueued (else the tap
// won't fire on the pre-rolled item); the AU's stream format must match the ASBD
// the tap hands us in `prepare`; `MaximumFramesPerSlice` must be set before
// `AudioUnitInitialize`; filter state is reset on a seek (`startOfStream`); band
// gains are pushed live from the main thread via the thread-safe
// `AudioUnitSetParameter`; and the C callbacks manage their `Unmanaged` retain by
// hand (retain at creation, release in `finalize`).

/// The coordinator the app and `PlaybackEngine` talk to. Owns the authoritative
/// ``EqualizerSettings`` and the master on/off, mints a tap per player item, and
/// broadcasts live gain changes to every currently-attached tap.
@MainActor
public final class EqualizerProcessor {
    /// The master switch. Changing it requires the engine to rebuild loaded items
    /// (so all queued items are homogeneously tapped/untapped — a hard requirement
    /// for gapless), so the engine owns the setter side-effect; this is just state.
    public var isEnabled: Bool

    /// The current curve. `apply(_:)` mutates this and pushes to live taps.
    public private(set) var settings: EqualizerSettings

    /// Weak handles to taps currently attached to loaded items (at most the
    /// current + one pre-rolled item). Pruned lazily; a tap's context deallocates
    /// when its item/mix is released and the tap finalizes.
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

    /// Replace the curve and push it to every live tap — a real-time-safe,
    /// glitch-free update (no reload, no gap).
    public func apply(_ newSettings: EqualizerSettings) {
        settings = newSettings
        contexts.removeAll { $0.value == nil }
        for box in contexts { box.value?.update(settings: newSettings) }
    }
}

// MARK: - Per-item tap context

/// Owns the Audio Unit for a single tapped `AVPlayerItem` and bridges between the
/// real-time audio callbacks and the main thread's live gain updates.
///
/// Threading: `prepare` / `unprepare` / `process` / `finalize` are all delivered
/// on the same serial audio-processing thread, so the `au` reference is only
/// mutated there. The only cross-thread contact is `update(settings:)` from the
/// main thread, which is serialized against `au` teardown by `lock`;
/// `AudioUnitSetParameter` itself is documented safe to call concurrently with
/// rendering.
final class EqualizerTapContext {
    // A heap-stable unfair lock (iOS 16+). Do NOT use a bare `os_unfair_lock`
    // stored property with `&lock`: Swift doesn't guarantee a stable address for
    // `&` of a stored property, which would silently break mutual exclusion.
    private let lock = OSAllocatedUnfairLock()
    private var au: EqualizerAudioUnit?
    private var gains: [Double]
    private var preampDB: Double

    /// Set for the duration of a single `AudioUnitRender` so the AU's input render
    /// callback can copy the tap's source samples. Audio-thread only.
    fileprivate var pendingSource: UnsafePointer<AudioBufferList>?
    /// Monotonic sample clock for the render timestamp.
    private var sampleTime: Float64 = 0

    init(settings: EqualizerSettings) {
        self.gains = settings.gains
        self.preampDB = settings.preampDB
    }

    deinit {
        // Safety net: if the AU somehow outlived `unprepare`, release it. By the
        // time deinit runs (from the tap's finalize) no callbacks can be in flight.
        au?.dispose()
    }

    // MARK: Main thread

    /// Push new gains to the live AU (no-op until `prepare` has built it).
    func update(settings: EqualizerSettings) {
        lock.lock()
        gains = settings.gains
        preampDB = settings.preampDB
        au?.applyGains(gains, preampDB: preampDB)
        lock.unlock()
    }

    // MARK: Audio thread — tap lifecycle

    func prepare(maxFrames: CMItemCount, format: AudioStreamBasicDescription) {
        let unit = EqualizerAudioUnit()
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        guard unit.create(),
              unit.configure(format: format, maxFrames: UInt32(maxFrames), renderContext: refCon) else {
            unit.dispose()
            return
        }
        lock.lock()
        unit.applyGains(gains, preampDB: preampDB)
        au = unit
        lock.unlock()
    }

    func unprepare() {
        lock.lock()
        au?.dispose()
        au = nil
        lock.unlock()
    }

    // MARK: Audio thread — render

    func process(tap: MTAudioProcessingTap,
                 numberFrames: CMItemCount,
                 flags: MTAudioProcessingTapFlags,
                 bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                 numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                 flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
        // `au` is only mutated on this (audio) thread, so a plain read is safe.
        guard let unit = au else {
            _ = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
            return
        }
        // Pull the source audio into the shared buffer list.
        let getStatus = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
        guard getStatus == noErr else { return }

        // A seek restarts the stream: clear the biquad state so it doesn't click.
        // The start/end-of-stream signal is returned via `flagsOut` from
        // `MTAudioProcessingTapGetSourceAudio`, not the incoming `flags`.
        if (flagsOut.pointee & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_StartOfStream)) != 0 {
            unit.reset()
        }

        let frames = UInt32(numberFramesOut.pointee)
        guard frames > 0 else { return }

        pendingSource = UnsafePointer(bufferListInOut)
        defer { pendingSource = nil }

        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        ts.mSampleTime = sampleTime
        var renderFlags = AudioUnitRenderActionFlags()
        // Render in place; the AU pulls its input via `copySource(into:)`, then
        // writes the equalized result back into the same buffer list. If it fails,
        // the buffer still holds the untouched source, so audio keeps playing.
        if unit.render(frames: frames, flags: &renderFlags, timestamp: &ts, bufferList: bufferListInOut) == noErr {
            sampleTime += Float64(frames)
        }
    }

    /// Copy the stashed source samples into the AU's input buffer. Called by the
    /// AU's render callback during `AudioUnitRender` — real-time, no allocation.
    /// Fills every destination buffer fully (source bytes, then zero-padded) and
    /// uses `memmove` so the in-place same-buffer case is well-defined.
    fileprivate func copySource(into ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let dst = UnsafeMutableAudioBufferListPointer(ioData)
        guard let source = pendingSource else {
            for buffer in dst { if let d = buffer.mData { memset(d, 0, Int(buffer.mDataByteSize)) } }
            return noErr
        }
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        for i in 0..<dst.count {
            guard let d = dst[i].mData else { continue }
            let dstBytes = Int(dst[i].mDataByteSize)
            if i < src.count, let s = src[i].mData {
                let copyBytes = min(Int(src[i].mDataByteSize), dstBytes)
                memmove(d, s, copyBytes)
                if copyBytes < dstBytes { memset(d + copyBytes, 0, dstBytes - copyBytes) }
            } else {
                // No matching source channel — silence rather than leave it stale.
                memset(d, 0, dstBytes)
            }
        }
        return noErr
    }
}

// MARK: - NBandEQ Audio Unit wrapper

/// A thin wrapper over one `kAudioUnitSubType_NBandEQ` instance configured as a
/// 10-band graphic EQ at the app's ISO center frequencies.
private final class EqualizerAudioUnit {
    private var unit: AudioComponentInstance?

    func create() -> Bool {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_NBandEQ,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { return false }
        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else { return false }
        unit = instance
        return true
    }

    /// Configure stream format, band topology, max slice, and the input render
    /// callback, then initialize. Everything that must precede
    /// `AudioUnitInitialize` happens here, in order.
    func configure(format: AudioStreamBasicDescription, maxFrames: UInt32, renderContext: UnsafeMutableRawPointer) -> Bool {
        guard let unit else { return false }
        var asbd = format

        let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, fmtSize) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, fmtSize) == noErr
        else { return false }

        // Ten bands at our ISO frequencies, parametric peaking filters. The band
        // count is critical (our per-band param IDs assume it); bail to a
        // passthrough (no tap) if it can't be set rather than mis-address bands.
        var bandCount = UInt32(EqualizerSettings.bandCount)
        guard AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0,
                                   &bandCount, UInt32(MemoryLayout<UInt32>.size)) == noErr
        else { return false }
        for i in 0..<EqualizerSettings.bandCount {
            let band = AudioUnitParameterID(i)
            // AUNBandEQ bands default to BYPASSED — without this every per-band gain
            // is inaudible while only the global preamp works. 0 = band active.
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUNBandEQParam_BypassBand) + band,
                                  kAudioUnitScope_Global, 0,
                                  AudioUnitParameterValue(0), 0)
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUNBandEQParam_FilterType) + band,
                                  kAudioUnitScope_Global, 0,
                                  AudioUnitParameterValue(kAUNBandEQFilterType_Parametric), 0)
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUNBandEQParam_Frequency) + band,
                                  kAudioUnitScope_Global, 0,
                                  AudioUnitParameterValue(EqualizerSettings.centerFrequencies[i]), 0)
        }

        // Cap the render slice generously; the tap can deliver large buffers on
        // iPad. MUST be set before AudioUnitInitialize, and is critical: too small
        // and a big slice fails to render (silence), so bail to passthrough.
        var maxSlice = max(maxFrames, 8192)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                   &maxSlice, UInt32(MemoryLayout<UInt32>.size)) == noErr
        else { return false }

        var callback = AURenderCallbackStruct(inputProc: equalizerRenderCallback, inputProcRefCon: renderContext)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
        else { return false }

        return AudioUnitInitialize(unit) == noErr
    }

    /// Set every band gain plus the global preamp. Thread-safe against rendering.
    func applyGains(_ gains: [Double], preampDB: Double) {
        guard let unit else { return }
        for i in 0..<min(gains.count, EqualizerSettings.bandCount) {
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUNBandEQParam_Gain) + AudioUnitParameterID(i),
                                  kAudioUnitScope_Global, 0, AudioUnitParameterValue(gains[i]), 0)
        }
        AudioUnitSetParameter(unit, AudioUnitParameterID(kAUNBandEQParam_GlobalGain),
                              kAudioUnitScope_Global, 0, AudioUnitParameterValue(preampDB), 0)
    }

    func render(frames: UInt32,
                flags: inout AudioUnitRenderActionFlags,
                timestamp: inout AudioTimeStamp,
                bufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        return AudioUnitRender(unit, &flags, &timestamp, 0, frames, bufferList)
    }

    func reset() {
        guard let unit else { return }
        AudioUnitReset(unit, kAudioUnitScope_Global, 0)
    }

    func dispose() {
        guard let unit else { return }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }
}

// MARK: - C callbacks

/// The AU's input render callback: copy the tap's stashed source into the AU's
/// input buffer. `inputProcRefCon` is an unretained pointer to the context, which
/// outlives the AU (the tap owns a retain on it).
private let equalizerRenderCallback: AURenderCallback = { refCon, _, _, _, _, ioData in
    guard let ioData else { return noErr }
    let context = Unmanaged<EqualizerTapContext>.fromOpaque(refCon).takeUnretainedValue()
    return context.copySource(into: ioData)
}

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
        // Creation failed: balance the retain, since finalize will never run.
        Unmanaged<EqualizerTapContext>.fromOpaque(rawContext).release()
        return nil
    }
    return tap
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    // Hand the retained context pointer to tap storage for later callbacks.
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    // Balance the passRetained at creation.
    Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    let context = Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.prepare(maxFrames: maxFrames, format: format.pointee)
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
